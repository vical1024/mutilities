import Carbon
import Foundation

// Read-only: reports whether Secure Event Input is on (it hides key events from event taps) and which process holds it.
print("secureEventInput=\(IsSecureEventInputEnabled())")
