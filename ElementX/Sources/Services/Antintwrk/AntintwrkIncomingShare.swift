// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

struct AntintwrkIncomingShare {
    let id = UUID().uuidString
    let text: String
    let files: [[String: String]]
    
    init(_ payload: ShareExtensionPayload) throws {
        switch payload {
        case .text(_, let text):
            guard text.utf8.count <= 100_000 else { throw AntintwrkSocialClient.Failure.invalidResponse }
            self.text = text; files = []
        case .mediaFiles(_, let media):
            guard (1...10).contains(media.count) else { throw AntintwrkSocialClient.Failure.invalidResponse }
            text = ""
            var total = 0
            files = try media.map { file in
                let path = file.url.standardizedFileURL.resolvingSymlinksInPath()
                let roots = [URL.appGroupTemporaryDirectory, URL.temporaryDirectory].map { $0.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
                guard path.isFileURL, roots.contains(where: { path.path.hasPrefix($0) }),
                      let type = UTType(filenameExtension: path.pathExtension), type.conforms(to: .image) || type.conforms(to: .movie),
                      let mime = type.preferredMIMEType else { throw AntintwrkSocialClient.Failure.invalidResponse }
                let values = try path.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 20_000_000, total + size <= 20_000_000 else { throw AntintwrkSocialClient.Failure.invalidResponse }
                total += size
                let data = try Data(contentsOf: path, options: .mappedIfSafe)
                return ["name": String((file.suggestedName ?? path.lastPathComponent).prefix(120)), "mime": mime, "data": data.base64EncodedString()]
            }
        }
    }
    
    var script: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id, "text": text, "files": files]), let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.antintwrkImportNativeShare?.(" + json + ")"
    }
}
