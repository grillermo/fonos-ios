import Darwin
import os

/// The two numbers that decide whether iOS kills the app for memory.
struct ProcessMemorySnapshot: Codable, Equatable, Sendable {
    /// `phys_footprint`, the figure jetsam compares against the app's limit.
    var footprintMB: Int
    /// `os_proc_available_memory()`: how much more the app may allocate before
    /// iOS kills it. Always 0 on the Simulator, which has no jetsam limit.
    var availableMB: Int
}

enum ProcessMemory {
    static func snapshot() -> ProcessMemorySnapshot {
        ProcessMemorySnapshot(
            footprintMB: footprintMB(),
            availableMB: Int(os_proc_available_memory() / 1_048_576)
        )
    }

    /// -1 when the kernel call fails.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_048_576)
    }
}
