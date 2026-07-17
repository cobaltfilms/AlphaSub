import Foundation
import AlphaSubCore

// FCPXML (Final Cut Pro X XML) importer and exporter are implemented in
// FCPXMLFormat.swift. They were previously stubbed here; the stubs returned a
// phantom empty track and empty Data, which lied to callers. See
// FCPXMLFormat.swift for the real implementation.

// MARK: - Auto-registration in FormatRegistry

/// Call this once at app launch to register all built-in format handlers.
public func registerAllFormats() {
    let registry = FormatRegistry.shared

    // Importers
    registry.registerImporter(SRTImporter.self)
    registry.registerImporter(WebVTTImporter.self)
    registry.registerImporter(TTMLImporter.self)
    registry.registerImporter(ASSImporter.self)
    registry.registerImporter(TXTImporter.self)
    registry.registerImporter(AVIDImporter.self)
    registry.registerImporter(XLSXImporter.self)
    registry.registerImporter(PremiereImporter.self)
    registry.registerImporter(FCPXMLImporter.self)

    // Exporters
    registry.registerExporter(SRTExporter.self)
    registry.registerExporter(WebVTTExporter.self)
    registry.registerExporter(TTMLExporter.self)
    registry.registerExporter(DaVinciTTMLExporter.self)
    registry.registerExporter(ASSExporter.self)
    registry.registerExporter(TXTExporter.self)
    registry.registerExporter(AVIDExporter.self)
    registry.registerExporter(XLSXExporter.self)
    registry.registerExporter(DOCXExporter.self)
    registry.registerExporter(PremiereExporter.self)
    registry.registerExporter(FCPXMLExporter.self)
}