import SwiftUI

// Explicitly name the property-wrapper type: macOS 27's SDK also exports a State macro,
// whose plugin is not shipped with the standalone Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
