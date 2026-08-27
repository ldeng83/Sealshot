import Foundation

/// The drawing tool an annotation geometry belongs to, or nil for geometries
/// that have no tool default (blur is the redaction tool with its own defaults;
/// image overlays and cut regions have no style tool). Used to write a
/// per-object style edit back to that tool's creation default.
func geometryTool(_ geometry: Geometry) -> EditorTool? {
    switch geometry {
    case .rectangle: return .rectangle
    case .ellipse:   return .ellipse
    case .arrow:     return .arrow
    case .line:      return .line
    case .text:      return .text
    case .badge:     return .badge
    case .pen:       return .pen
    case .penArrow:  return .penArrow
    case .blur, .image, .cut: return nil
    }
}
