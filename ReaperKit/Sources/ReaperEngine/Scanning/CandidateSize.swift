/// How big a candidate is, and how much of that may stay on disk after deleting it.
public struct CandidateSize: Hashable, Sendable {

    /// Bytes allocated by the files inside, each hard-linked file counted once. Clones count in
    /// full, as Finder counts them, although they share blocks.
    public var allocated: UInt64 = 0
    /// Bytes in files that also have hard links outside the candidate. Deleting the candidate
    /// removes its links, but the files stay until every link is gone.
    public var hardLinkedBytes: UInt64 = 0
    /// Files counted in ``hardLinkedBytes``.
    public var hardLinkedFiles = 0
    /// Bytes in files that share blocks with clones, inside the candidate or outside it.
    /// Deleting them frees only the blocks no remaining clone uses.
    public var clonedBytes: UInt64 = 0
    /// Files counted in ``clonedBytes``.
    public var clonedFiles = 0
    public var files = 0
    /// Directories inside, the candidate itself included.
    public var directories = 0
    /// `false` when part of the candidate could not be read; the sizes are then lower bounds.
    public var isComplete = true

    public init(
        allocated: UInt64 = 0,
        hardLinkedBytes: UInt64 = 0,
        hardLinkedFiles: Int = 0,
        clonedBytes: UInt64 = 0,
        clonedFiles: Int = 0,
        files: Int = 0,
        directories: Int = 0,
        isComplete: Bool = true
    ) {
        self.allocated = allocated
        self.hardLinkedBytes = hardLinkedBytes
        self.hardLinkedFiles = hardLinkedFiles
        self.clonedBytes = clonedBytes
        self.clonedFiles = clonedFiles
        self.files = files
        self.directories = directories
        self.isComplete = isComplete
    }

    /// Bytes that may stay on disk after deleting the candidate, because other files share
    /// them. Deleting it frees at least ``allocated`` minus these.
    public var sharedBytes: UInt64 {
        hardLinkedBytes + clonedBytes
    }

    /// Whether deleting the candidate may free less than ``allocated``.
    public var mayFreeLess: Bool {
        sharedBytes > 0
    }

    /// Adds `other` as if it were a separate candidate: a file hard-linked into both counts
    /// twice.
    public mutating func add(_ other: CandidateSize) {
        allocated += other.allocated
        hardLinkedBytes += other.hardLinkedBytes
        hardLinkedFiles += other.hardLinkedFiles
        clonedBytes += other.clonedBytes
        clonedFiles += other.clonedFiles
        files += other.files
        directories += other.directories
        isComplete = isComplete && other.isComplete
    }

    /// Adds a file that no link outside the candidate holds.
    mutating func addFile(allocated bytes: UInt64, sharesBlocks: Bool) {
        allocated += bytes
        if sharesBlocks {
            clonedBytes += bytes
            clonedFiles += 1
        }
    }
}
