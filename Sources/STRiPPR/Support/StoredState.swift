import SwiftUI

// Select the stable property-wrapper type explicitly. The macOS 27 SDK also
// introduces an identically named macro whose plugin is absent from CLT builds.
typealias StoredState<Value> = SwiftUI.State<Value>
