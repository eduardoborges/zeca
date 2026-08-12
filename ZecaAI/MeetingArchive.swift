import Foundation
import UniformTypeIdentifiers

/// Manifesto dentro do .zeca: quem exportou, quando, e de onde veio.
/// O importedAt e carimbado na hora do import e fica no zeca.json da pasta.
struct ZecaManifest: Codable {
    var version: Int
    var folder: String
    var title: String?
    var author: String
    var exportedAt: Date
    var importedAt: Date?
}

/// Um .zeca e um zip da pasta da gravacao (audio, transcript.json, summary.md,
/// notes.md, title.txt, offsets.json) mais um zeca.json com o manifesto.
/// Um .zeca aberto (descompactado num temporario) mas ainda nao importado.
/// O Recording aponta pro temporario, entao o preview reusa os accessors dele.
struct ZecaPreview: Identifiable {
    let manifest: ZecaManifest
    let folder: URL
    var id: URL { folder }
    var recording: Recording { Recording(url: folder) }

    func discard() {
        // O wrapper (UUID) e nosso; apaga ele inteiro, nao so a pasta de dentro.
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }
}

enum MeetingArchive {
    static let fileType = UTType(exportedAs: "com.zeca.meeting")

    private static var json: (encoder: JSONEncoder, decoder: JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// Copia a pasta pra um temporario, injeta o zeca.json e zipa em dest.
    static func export(_ recording: Recording, to dest: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: recording.url, to: tmp)
        let manifest = ZecaManifest(
            version: 1,
            folder: recording.name,
            title: recording.customTitle,
            author: NSFullUserName(),
            exportedAt: Date(),
            importedAt: nil)
        try json.encoder.encode(manifest).write(to: tmp.appendingPathComponent("zeca.json"))
        try? FileManager.default.removeItem(at: dest)
        try run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", tmp.path, dest.path)
    }

    /// Descompacta num temporario e le o manifesto, sem importar nada ainda.
    /// Quem chama importa com finishImport ou joga fora com discard.
    /// A pasta final leva o nome original da reuniao (dentro de um wrapper
    /// unico), pro Recording do preview derivar data e titulo direito.
    static func peek(_ source: URL) throws -> ZecaPreview {
        let wrapper = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            let unpacked = wrapper.appendingPathComponent("unpacked")
            try run("/usr/bin/ditto", "-x", "-k", source.path, unpacked.path)
            let data = try Data(contentsOf: unpacked.appendingPathComponent("zeca.json"))
            let manifest = try json.decoder.decode(ZecaManifest.self, from: data)
            let folder = wrapper.appendingPathComponent(manifest.folder)
            try FileManager.default.moveItem(at: unpacked, to: folder)
            return ZecaPreview(manifest: manifest, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: wrapper)
            throw error
        }
    }

    /// Carimba importedAt no manifesto e move o temporario pra Recordings.
    static func finishImport(_ preview: ZecaPreview) throws -> URL {
        var manifest = preview.manifest
        manifest.importedAt = Date()
        try json.encoder.encode(manifest).write(to: preview.folder.appendingPathComponent("zeca.json"))
        try FileManager.default.createDirectory(at: Recorder.root, withIntermediateDirectories: true)
        // ponytail: colisao ganha sufixo " (2)"; a pasta perde a data derivada do
        // nome, mas o title.txt segura o titulo na tela.
        var dest = Recorder.root.appendingPathComponent(manifest.folder)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = Recorder.root.appendingPathComponent("\(manifest.folder) (\(n))")
            n += 1
        }
        try FileManager.default.moveItem(at: preview.folder, to: dest)
        try? FileManager.default.removeItem(at: preview.folder.deletingLastPathComponent())
        return dest
    }

    /// Import direto, sem preview (botao da toolbar).
    static func importArchive(from source: URL) throws -> URL {
        let preview = try peek(source)
        do { return try finishImport(preview) } catch {
            preview.discard()
            throw error
        }
    }

    private static func run(_ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ZecaAI", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not read or write the .zeca archive."])
        }
    }
}
