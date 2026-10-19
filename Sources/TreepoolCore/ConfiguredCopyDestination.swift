import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Anchors writes to the slot directory and never follows destination ancestor symlinks.
final class ConfiguredCopyDestination {
    private let rootDescriptor: Int32

    init(root: URL) throws {
        // Resolve the trusted slot root (including system aliases such as /tmp) once.
        rootDescriptor = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw failure("open copy destination") }
    }

    deinit { close(rootDescriptor) }

    func validateParent(of path: String) throws {
        if let descriptor = try parentDescriptor(for: path, create: false) { close(descriptor) }
    }

    func copyFile(from source: URL, to path: String) throws {
        guard let parent = try parentDescriptor(for: path, create: true) else {
            throw TreepoolError.unsafe("Missing copy destination parent for '\(path)'.")
        }
        defer { close(parent) }
        let temporaryName = ".twt-copy-\(UUID().uuidString)"
        defer { _ = unlinkat(parent, temporaryName, 0) }

        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path) {
            guard symlinkat(link, parent, temporaryName) == 0 else {
                throw failure("copy symbolic link '\(path)'")
            }
        } else {
            let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw failure("open copy source '\(path)'") }
            defer { close(input) }
            var metadata = stat()
            guard fstat(input, &metadata) == 0 else { throw failure("inspect copy source '\(path)'") }
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw TreepoolError.unsafe("copyPatterns source '\(path)' must be a regular file or symbolic link.")
            }

            let output = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw failure("create copy destination '\(path)'") }
            defer { close(output) }
            #if canImport(Darwin)
            // Preserve file metadata, including ACLs and extended attributes, without
            // reopening the destination by path.
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                throw failure("copy file '\(path)'")
            }
            #else
            let reader = FileHandle(fileDescriptor: input, closeOnDealloc: false)
            let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
            while let data = try reader.read(upToCount: 64 * 1024), !data.isEmpty {
                try writer.write(contentsOf: data)
            }
            #endif
            guard fchmod(output, metadata.st_mode & 0o777) == 0 else {
                throw failure("set copy permissions '\(path)'")
            }
        }

        // renameat replaces a leaf symlink itself, never its target. It also refuses
        // to replace a directory, rather than recursively removing its contents.
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard renameat(parent, temporaryName, parent, name) == 0 else {
            throw failure("replace copy destination '\(path)'")
        }
    }

    private func parentDescriptor(for path: String, create: Bool) throws -> Int32? {
        let components = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw TreepoolError.unsafe("Unsafe copy destination '\(path)'.")
        }
        var descriptor = dup(rootDescriptor)
        guard descriptor >= 0 else { throw failure("open copy destination parent") }
        do {
            for component in components.dropLast() {
                var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    guard create else {
                        close(descriptor)
                        return nil
                    }
                    guard mkdirat(descriptor, component, 0o755) == 0 || errno == EEXIST else {
                        throw failure("create copy destination parent '\(path)'")
                    }
                    next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else {
                    throw failure("copy destination parent '\(path)' must be a directory, not a symbolic link")
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }
}

private func failure(_ action: String) -> TreepoolError {
    let message = String(cString: strerror(errno))
    return .unsafe("Could not \(action): \(message).")
}
