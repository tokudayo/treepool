import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class RepositoryLock {
    private var descriptor: Int32 = -1

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TreepoolError.locked }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw TreepoolError.locked
        }
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
