import Foundation

public enum WriterDestination {
    public enum Error: LocalizedError {
        case cannotOpen(url: URL)
    }

    case file(URL)
    case memory

    public func outputStream() throws -> sending OutputStream {
        switch self {
        case .file(let url):
            guard let outputStream = OutputStream(url: url, append: false) else {
                throw Error.cannotOpen(url: url)
            }
            return outputStream
        case .memory:
            return OutputStream(toMemory: ())
        }
    }
}
