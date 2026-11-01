import Darwin
import Foundation

/// Attribue un processus d'aide (rendu Chrome, XPC…) à l'appli responsable. Fonction de libquarantine, sans autorisation requise.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePID(_ pid: pid_t) -> pid_t

/// Lecture de l'état réel de la machine (Mach, sysctl, libproc). Aucun droit administrateur requis.
public enum MemoryProbe {
    private static let host = mach_host_self()

    public static func counters() -> VMCounters? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMCounters(pageSize: UInt64(vm_kernel_page_size),
                          wired: UInt64(stats.wire_count),
                          compressor: UInt64(stats.compressor_page_count),
                          internalPages: UInt64(stats.internal_page_count),
                          externalPages: UInt64(stats.external_page_count),
                          purgeable: UInt64(stats.purgeable_count))
    }

    private static func sysctlValue<T: BitwiseCopyable>(_ name: String, _ initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    public static func snapshot() -> MemorySnapshot? {
        guard let counters = counters() else { return nil }
        let total = sysctlValue("hw.memsize", UInt64(0)) ?? 0
        let swap = sysctlValue("vm.swapusage", xsw_usage())?.xsu_used ?? 0
        let level = sysctlValue("kern.memorystatus_vm_pressure_level", Int32(1)) ?? 1
        return MemorySnapshot(counters: counters, total: total, swapUsed: swap,
                              pressure: PressureLevel(rawValue: Int(level)) ?? .normal)
    }

    /// Empreinte mémoire de chaque processus lisible, cumulée sur son processus responsable.
    public static func footprintsByResponsiblePID() -> [pid_t: UInt64] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [:] }
        var totals: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue } // processus d'un autre utilisateur, ou déjà terminé
            let owner = responsiblePID(pid)
            totals[owner > 0 ? owner : pid, default: 0] += usage.ri_phys_footprint
        }
        return totals
    }
}
