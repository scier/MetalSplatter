import Foundation

public enum ReaderSource {
    public enum Error: LocalizedError {
        case cannotOpen(url: URL)
    }

    case url(URL)
    case memory(Data)

    public func inputStream() throws -> InputStream {
        switch self {
        case .url(let url):
            guard let inputStream = InputStream(url: url) else {
                throw Error.cannotOpen(url: url)
            }
            return inputStream
        case .memory(let data):
            return InputStream(data: data)
        }
    }
}
