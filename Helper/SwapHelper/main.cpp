// SwapHelper (LaunchDaemon bundled in mutilities.app): root helper that swaps Ctrl<->Cmd below the event-tap layer via the
// Karabiner-DriverKit-VirtualHIDDevice virtual keyboard, so it also works in Secure Input fields.
//
// Safety model (a seized keyboard that nobody forwards is a lockout):
//   * Lease: the helper seizes a keyboard ONLY while <control-dir>/lease has an mtime newer than --lease-seconds.
//     The controlling app renews it (touch). If the app dies/hangs, or nobody ever created it (boot, login),
//     the keyboard is released/never seized. The helper never creates the lease itself.
//   * The virtual keyboard must be ready, otherwise the keyboard is released.
//   * A keyboard with a key currently held is not seized (the key-up would never reach macOS -> stuck key).
//   * On release the virtual keyboard gets an all-keys-up state.
//   * If this process dies, the kernel closes the seize, so the physical keyboard comes back on its own.
//   * Kill switch: Left Shift + Right Shift + Esc (physical keys) releases at once and creates <control-dir>/disable.
//     While `disable` exists nothing is seized, lease or not. Delete it to re-enable.
//   * Only one helper per control dir (flock on <control-dir>/helper.lock).
//   * Restart-instead-of-recover: on device removal, a newly attached keyboard, or wake from sleep the helper
//     exits and launchd (KeepAlive) starts a fresh one that enumerates devices again.
//   * Starts Karabiner-VirtualHIDDevice-Daemon itself when it is not running.
// Control files in --control-dir: `lease` (touch to keep seizing), `fnstate` ("on"/"off", optional), `disable`.
// The helper writes `status`: active | waiting | idle | starting | denied | disabled | no-keyboard.
//
// Build: see build.sh. Run (root): sudo ./kbd_helper --control-dir DIR --match "Apple Internal" [--lease-seconds 10] [--log]
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <libproc.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <atomic>
#include <csignal>
#include <ctime>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>

namespace drv = pqrs::karabiner::driverkit;
namespace rep = drv::virtual_hid_device_driver::hid_report;
using client_t = drv::virtual_hid_device_service::client;

static std::mutex g_mutex;
static client_t* g_client = nullptr;
static std::atomic<bool> g_ready(false);
static bool g_killRequested = false;  // kill chord seen; acted on in tick() (not inside the device callback)
static bool g_denied = false;         // IOHIDDeviceOpen returned kIOReturnNotPermitted: Input Monitoring is missing
static bool g_log = false;

// Physical state mirrored onto the virtual keyboard.
static uint8_t g_mods = 0;         // modifier bits (HID usage 0xE0..0xE7 -> bit 0..7)
static std::set<uint16_t> g_keys;  // keyboard page keys
// Non-keyboard pages the virtual keyboard accepts (driver's report descriptor): 0x0C consumer (<=768),
// 0xFF Apple top case, 0xFF01 Apple vendor keyboard, 0x01 generic desktop. Each report is a set of pressed usages.
static std::map<uint32_t, std::set<uint16_t>> g_other;

// F1..F12 -> media/system usages from Karabiner-Elements' default fn_function_keys.
struct FnTarget { uint32_t page; uint16_t usage; };
static const FnTarget kFnTargets[12] = {
  {0x0C, 0x0070}, {0x0C, 0x006F}, {0xFF01, 0x0010}, {0xFF01, 0x0001}, {0x0C, 0x00CF}, {0x01, 0x009B},
  {0x0C, 0x00B4}, {0x0C, 0x00CD}, {0x0C, 0x00B3}, {0x0C, 0x00E2}, {0x0C, 0x00EA}, {0x0C, 0x00E9}};
static bool g_fnDown = false;
static bool g_fnStandard = true;  // com.apple.keyboard.fnState: true = F-keys are standard F-keys, Fn+F = media
static std::map<uint32_t, FnTarget> g_activeMedia;  // so key-up releases what key-down pressed

static std::string prop(IOHIDDeviceRef d, CFStringRef key) {
  auto v = (CFStringRef)IOHIDDeviceGetProperty(d, key);
  if (!v || CFGetTypeID(v) != CFStringGetTypeID()) return "";
  char buf[256];
  return CFStringGetCString(v, buf, sizeof buf, kCFStringEncodingUTF8) ? buf : "";
}

static void logf(const std::string& s) {
  time_t t = time(nullptr);
  char buf[16];
  strftime(buf, sizeof buf, "%H:%M:%S", localtime(&t));
  std::cerr << buf << " " << s << std::endl;
}

// Ctrl<->Cmd: bit0 LCtrl<->bit3 LCmd, bit4 RCtrl<->bit7 RCmd.
static uint8_t swapBits(uint8_t m) {
  uint8_t o = m & 0b01100110;
  if (m & 0x01) o |= 0x08;
  if (m & 0x08) o |= 0x01;
  if (m & 0x10) o |= 0x80;
  if (m & 0x80) o |= 0x10;
  return o;
}

static void post() {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_client || !g_ready) return;
  rep::keyboard_input r;
  uint8_t m = swapBits(g_mods);
  for (int i = 0; i < 8; ++i)
    if (m & (1 << i)) r.modifiers.insert(static_cast<rep::modifier>(1 << i));
  for (auto k : g_keys) r.keys.insert(k);
  g_client->async_post_report(r);
}

static bool isOtherPage(uint32_t page) { return page == 0x0C || page == 0xFF || page == 0xFF01 || page == 0x01; }

static void postOther(uint32_t page) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_client || !g_ready) return;
  auto fill = [&](auto& r) { for (auto k : g_other[page]) r.keys.insert(k); g_client->async_post_report(r); };
  switch (page) {
    case 0x0C: { rep::consumer_input r; fill(r); break; }
    case 0xFF: { rep::apple_vendor_top_case_input r; fill(r); break; }
    case 0xFF01: { rep::apple_vendor_keyboard_input r; fill(r); break; }
    case 0x01: { rep::generic_desktop_input r; fill(r); break; }
  }
}

// Forget all pressed state and tell the virtual keyboard that everything is up.
static void releaseVirtualKeys() {
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_keys.clear(); g_mods = 0; g_other.clear(); g_activeMedia.clear(); g_fnDown = false;
  }
  post();
  for (uint32_t page : {0x0Cu, 0xFFu, 0xFF01u, 0x01u}) postOther(page);
}

// One physical keyboard. While not seized it is still opened (non-exclusively) so its key events keep
// `pressed` up to date; a keyboard is only seized when nothing is held (Karabiner's "grabbable" idea).
struct Dev {
  IOHIDDeviceRef ref = nullptr;
  std::string name;
  bool seized = false;
  CFAbsoluteTime nextTry = 0;
  std::string lastDeferReason;
  std::set<uint64_t> pressed;  // (page << 32) | usage for keyboard keys, modifiers and Fn that are down
};

static void onValue(void* ctx, IOReturn, void*, IOHIDValueRef value) {
  auto el = IOHIDValueGetElement(value);
  uint32_t page = IOHIDElementGetUsagePage(el);
  uint32_t u = IOHIDElementGetUsage(el);
  bool down = IOHIDValueGetIntegerValue(value) != 0;
  if (g_log) std::cerr << "event page=0x" << std::hex << page << " usage=0x" << u << std::dec << " down=" << down << "\n";
  auto* dev = static_cast<Dev*>(ctx);
  if ((page == kHIDPage_KeyboardOrKeypad && u >= 0x04 && u <= 0xE7) || (page == 0xFF && u == 3)) {
    uint64_t key = (uint64_t(page) << 32) | u;
    if (down) dev->pressed.insert(key); else dev->pressed.erase(key);
  }
  if (!dev->seized) return;  // observing only: never forward events of a keyboard that is not seized
  auto held = [&](uint32_t usage) { return dev->pressed.count((uint64_t(kHIDPage_KeyboardOrKeypad) << 32) | usage) != 0; };
  if (down && held(0xE1) && held(0xE5) && held(0x29)) g_killRequested = true;  // LShift + RShift + Esc
  if (page != kHIDPage_KeyboardOrKeypad) {
    uint32_t maxUsage = page == 0x0C ? 768 : 255;
    if (!isOtherPage(page) || u == 0 || u > maxUsage) return;  // skip array/padding elements
    if (page == 0xFF && u == 3) g_fnDown = down;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      if (down) g_other[page].insert(u); else g_other[page].erase(u);
    }
    postOther(page);
    return;
  }
  // F1..F12: translate to media/system keys the way macOS does for an Apple keyboard.
  if (u >= 0x3A && u <= 0x45) {
    if (down) {
      bool media = g_fnStandard ? g_fnDown : !g_fnDown;
      if (media) {
        FnTarget t = kFnTargets[u - 0x3A];
        g_activeMedia[u] = t;
        { std::lock_guard<std::mutex> lock(g_mutex); g_other[t.page].insert(t.usage); }
        postOther(t.page);
        return;
      }
    } else if (auto it = g_activeMedia.find(u); it != g_activeMedia.end()) {
      FnTarget t = it->second;
      g_activeMedia.erase(it);
      { std::lock_guard<std::mutex> lock(g_mutex); g_other[t.page].erase(t.usage); }
      postOther(t.page);
      return;
    }
  }
  if (u >= 0xE0 && u <= 0xE7) {
    uint8_t bit = 1 << (u - 0xE0);
    g_mods = down ? (g_mods | bit) : (g_mods & ~bit);
  } else if (u >= 0x04 && u <= 0xDF) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (down) g_keys.insert(u); else g_keys.erase(u);
  } else return;  // 0x00..0x03 are rollover/error markers
  post();
}

//
// Devices
//
static std::vector<std::unique_ptr<Dev>> g_devs;
static std::vector<std::string> g_match;
static std::string g_controlDir;
static bool g_all = false;            // every physical keyboard (except the virtual one)
static std::atomic<bool> g_restart(false);  // exit so launchd starts a fresh helper
static double g_leaseSeconds = 10;

static bool wanted(IOHIDDeviceRef d) {
  std::string p = prop(d, CFSTR(kIOHIDProductKey)), m = prop(d, CFSTR(kIOHIDManufacturerKey));
  if (p.find("Karabiner") != std::string::npos || m.find("pqrs") != std::string::npos) return false;  // never grab the virtual keyboard
  if (g_all) return true;
  for (auto& s : g_match)
    if (!s.empty() && p.find(s) != std::string::npos) return true;
  return false;
}

static int numProp(IOHIDDeviceRef d, CFStringRef key) {
  int v = -1;
  auto n = (CFNumberRef)IOHIDDeviceGetProperty(d, key);
  if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberIntType, &v);
  return v;
}

static void seize(Dev& dev, CFAbsoluteTime now) {
  if (!g_ready) return;
  if (!dev.pressed.empty()) {
    uint64_t k = *dev.pressed.begin();
    char buf[96];
    snprintf(buf, sizeof buf, "%zu key(s) held, e.g. page=0x%x usage=0x%x", dev.pressed.size(), (unsigned)(k >> 32), (unsigned)(k & 0xFFFFFFFF));
    if (buf != dev.lastDeferReason) logf("deferring seize of '" + dev.name + "': " + buf);
    dev.lastDeferReason = buf;
    dev.nextTry = now + 0.2;
    return;
  }
  dev.lastDeferReason.clear();
  IOHIDDeviceClose(dev.ref, kIOHIDOptionsTypeNone);
  IOReturn r = IOHIDDeviceOpen(dev.ref, kIOHIDOptionsTypeSeizeDevice);
  if (r != kIOReturnSuccess) {
    IOHIDDeviceOpen(dev.ref, kIOHIDOptionsTypeNone);  // keep observing
    if (r == kIOReturnNotPermitted) g_denied = true;
    logf("seize '" + dev.name + "' failed (" + std::to_string(r) + "), retry in 1s");
    dev.nextTry = now + 1.0;
    return;
  }
  dev.seized = true;
  g_denied = false;
  logf("seized '" + dev.name + "'");
}

static void release(Dev& dev, const char* reason) {
  if (!dev.seized) return;
  IOHIDDeviceClose(dev.ref, kIOHIDOptionsTypeSeizeDevice);
  dev.seized = false;
  releaseVirtualKeys();
  IOHIDDeviceOpen(dev.ref, kIOHIDOptionsTypeNone);  // go back to observing
  logf("released '" + dev.name + "' (" + reason + ")");
}

static bool leaseValid() {
  struct stat st;
  if (stat((g_controlDir + "/lease").c_str(), &st) != 0) return false;
  double age = difftime(time(nullptr), st.st_mtime);
  return age <= g_leaseSeconds && age >= -2;
}

static void readFnState() {
  std::ifstream f(g_controlDir + "/fnstate");
  std::string v;
  if (f >> v) g_fnStandard = (v == "on");
}

static bool disabled() {
  struct stat st;
  return stat((g_controlDir + "/disable").c_str(), &st) == 0;
}

static std::atomic<bool> g_stop(false);

static void writeStatus(bool lease, bool off) {
  static std::string last;
  static CFAbsoluteTime lastWrite = 0;
  bool anySeized = false;
  for (auto& p : g_devs) anySeized = anySeized || p->seized;
  std::string st = g_devs.empty() ? "no-keyboard" : off ? "disabled" : anySeized ? "active" : g_denied ? "denied"
                 : !g_ready ? "starting" : lease ? "waiting" : "idle";
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (st == last && now - lastWrite < 1.0) return;  // the mtime doubles as a heartbeat
  std::string path = g_controlDir + "/status", tmp = path + ".tmp";
  if (FILE* f = fopen(tmp.c_str(), "w")) {
    fprintf(f, "%s\n", st.c_str());
    fclose(f);
    chmod(tmp.c_str(), 0644);
    rename(tmp.c_str(), path.c_str());
  }
  if (st != last) logf("status " + st);
  last = st;
  lastWrite = now;
}

static void tick(CFRunLoopTimerRef, void*) {
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  readFnState();
  bool lease = leaseValid();
  if (g_killRequested) {
    g_killRequested = false;
    if (int fd = open((g_controlDir + "/disable").c_str(), O_CREAT | O_WRONLY, 0644); fd >= 0) close(fd);
    for (auto& p : g_devs) release(*p, "kill switch: LShift+RShift+Esc");
    logf("disabled until " + g_controlDir + "/disable is removed");
  }
  bool off = disabled();
  for (auto& p : g_devs) {
    Dev& dev = *p;
    if (dev.seized) {
      if (off) release(dev, "disable file present");
      else if (!lease) release(dev, "lease expired");
      else if (!g_ready) release(dev, "virtual keyboard not ready");
    } else if (lease && !off && now >= dev.nextTry) {
      seize(dev, now);
    }
  }
  writeStatus(lease, off);
}

static const char* kVirtualHIDDaemon =
    "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/"
    "Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon";

// Checked in-process (libproc) rather than by running pgrep: a child process every few seconds shows up
// as background activity of the app in System Settings > Login Items.
static bool virtualHIDDaemonRunning() {
  int count = proc_listallpids(nullptr, 0);
  if (count <= 0) return true;  // can't tell; don't spawn duplicates
  std::vector<pid_t> pids(count + 32);
  count = proc_listallpids(pids.data(), int(pids.size() * sizeof(pid_t)));
  char path[PROC_PIDPATHINFO_MAXSIZE];
  for (int i = 0; i < count; ++i) {
    if (proc_pidpath(pids[i], path, sizeof path) > 0 && strcmp(path, kVirtualHIDDaemon) == 0) return true;
  }
  return false;
}

static void ensureVirtualHIDDaemon() {
  while (waitpid(-1, nullptr, WNOHANG) > 0) {}  // reap a daemon we started that exited
  if (virtualHIDDaemonRunning()) return;
  pid_t pid;
  char* const args[] = {const_cast<char*>(kVirtualHIDDaemon), nullptr};
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
  int rc = posix_spawn(&pid, kVirtualHIDDaemon, &fa, nullptr, args, nullptr);
  posix_spawn_file_actions_destroy(&fa);
  logf(rc == 0 ? "started Karabiner-VirtualHIDDevice-Daemon pid " + std::to_string(pid)
               : "failed to start Karabiner-VirtualHIDDevice-Daemon (" + std::to_string(rc) + ")");
}

static void daemonTick(CFRunLoopTimerRef, void*) { ensureVirtualHIDDaemon(); }

static io_connect_t g_rootPort = 0;
static void onPower(void*, io_service_t, natural_t type, void* arg) {
  switch (type) {
    case kIOMessageCanSystemSleep:
    case kIOMessageSystemWillSleep:
      IOAllowPowerChange(g_rootPort, (long)arg);
      break;
    case kIOMessageSystemHasPoweredOn:
      logf("woke from sleep; restarting to re-open keyboards");
      g_restart = true;
      break;
  }
}

static void onDeviceRemoved(void* ctx, IOReturn, void*) {
  logf("keyboard '" + static_cast<Dev*>(ctx)->name + "' removed; restarting");
  g_restart = true;
}

static bool g_initialScanDone = false;
static void onNewHIDService(void*, io_iterator_t it) {
  bool newKeyboard = false;
  while (io_service_t svc = IOIteratorNext(it)) {
    if (g_initialScanDone && !newKeyboard) {
      if (IOHIDDeviceRef d = IOHIDDeviceCreate(kCFAllocatorDefault, svc)) {
        newKeyboard = numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey)) == 1 && numProp(d, CFSTR(kIOHIDPrimaryUsageKey)) == 6 && wanted(d);
        if (newKeyboard) logf("new keyboard '" + prop(d, CFSTR(kIOHIDProductKey)) + "' attached; restarting");
        CFRelease(d);
      }
    }
    IOObjectRelease(svc);
  }
  if (newKeyboard) g_restart = true;
}

int main(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--control-dir" && i + 1 < argc) g_controlDir = argv[++i];
    else if (a == "--match" && i + 1 < argc) g_match.push_back(argv[++i]);
    else if (a == "--lease-seconds" && i + 1 < argc) g_leaseSeconds = atof(argv[++i]);
    else if (a == "--log") g_log = true;
    else if (a == "--all") g_all = true;
  }
  if (g_controlDir.empty() || (g_match.empty() && !g_all)) {
    std::cerr << "usage: kbd_helper --control-dir DIR --match <product substring> [--match ...] [--lease-seconds N] [--log]\n";
    return 2;
  }

  mkdir(g_controlDir.c_str(), 0777);
  chmod(g_controlDir.c_str(), 0777);  // the user-level agent writes `lease` and `fnstate` here
  int lockFd = open((g_controlDir + "/helper.lock").c_str(), O_CREAT | O_RDWR, 0644);
  if (lockFd < 0 || flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
    logf("another kbd_helper already uses " + g_controlDir + "; exiting");
    return 3;
  }
  if (disabled()) logf("note: " + g_controlDir + "/disable exists; nothing will be seized until it is removed");

  ensureVirtualHIDDaemon();
  pqrs::dispatcher::extra::initialize_shared_dispatcher();
  auto client = std::make_unique<client_t>();
  client->warning_reported.connect([](auto&& m) { logf("warning: " + std::string(m)); });
  client->connected.connect([&client] {
    logf("daemon connected");
    drv::virtual_hid_device_service::virtual_hid_keyboard_parameters p;
    p.set_country_code(pqrs::hid::country_code::us);
    client->async_virtual_hid_keyboard_initialize(p);
  });
  client->error_occurred.connect([](auto&& e) { logf("error_occurred " + std::to_string((int)e.value())); });
  client->closed.connect([] { logf("client closed"); g_ready = false; });
  client->connect_failed.connect([](auto&& e) { logf("connect_failed " + std::to_string((int)e.value())); g_ready = false; });
  client->driver_version_mismatched.connect([](auto&& v) { if (v) logf("driver_version_mismatched"); });
  client->virtual_hid_keyboard_ready.connect([](auto&& r) { logf(std::string("virtual keyboard ready ") + (r ? "1" : "0")); g_ready = r; });
  { std::lock_guard<std::mutex> lock(g_mutex); g_client = client.get(); }
  client->async_start();

  // One device object per matching keyboard (Karabiner-style: no IOHIDManager, which doubled events and leaked input).
  io_iterator_t it = 0;
  IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &it);
  while (io_service_t svc = IOIteratorNext(it)) {
    IOHIDDeviceRef d = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
    IOObjectRelease(svc);
    if (!d) continue;
    if (numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey)) != 1 || numProp(d, CFSTR(kIOHIDPrimaryUsageKey)) != 6 || !wanted(d)) { CFRelease(d); continue; }
    auto dev = std::make_unique<Dev>();
    dev->ref = d;
    dev->name = prop(d, CFSTR(kIOHIDProductKey));
    IOHIDDeviceRegisterInputValueCallback(d, onValue, dev.get());
    IOHIDDeviceRegisterRemovalCallback(d, onDeviceRemoved, dev.get());
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn orc = IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone);  // observe key state while not seized
    if (orc == kIOReturnNotPermitted) g_denied = true;
    logf("found keyboard '" + dev->name + "' (observing: " + (orc == kIOReturnSuccess ? "ok" : "open failed " + std::to_string(orc)) + ")");
    g_devs.push_back(std::move(dev));
  }
  IOObjectRelease(it);

  IONotificationPortRef notifyPort = IONotificationPortCreate(kIOMainPortDefault);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(notifyPort), kCFRunLoopDefaultMode);
  io_iterator_t addedIt = 0;
  IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification, IOServiceMatching(kIOHIDDeviceKey), onNewHIDService, nullptr, &addedIt);
  onNewHIDService(nullptr, addedIt);  // drain the existing services to arm the notification
  g_initialScanDone = true;
  IONotificationPortRef powerPort = nullptr;
  io_object_t powerNotifier = 0;
  g_rootPort = IORegisterForSystemPower(nullptr, &powerPort, onPower, &powerNotifier);
  if (powerPort) CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(powerPort), kCFRunLoopDefaultMode);
  CFRunLoopTimerRef daemonTimer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0, daemonTick, nullptr);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), daemonTimer, kCFRunLoopDefaultMode);
  logf("lease file: " + g_controlDir + "/lease (valid for " + std::to_string((int)g_leaseSeconds) + "s after its mtime); nothing is seized until it exists");

  std::signal(SIGINT, [](int) { g_stop = true; });
  std::signal(SIGTERM, [](int) { g_stop = true; });
  CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0.2, 0, 0, tick, nullptr);
  CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
  while (!g_stop && !g_restart) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);

  for (auto& p : g_devs) {
    release(*p, "shutting down");
    IOHIDDeviceClose(p->ref, kIOHIDOptionsTypeNone);
  }
  { std::lock_guard<std::mutex> lock(g_mutex); g_client = nullptr; }
  client = nullptr;
  pqrs::dispatcher::extra::terminate_shared_dispatcher();
  logf(g_restart ? "exit for restart" : "exit");
}
