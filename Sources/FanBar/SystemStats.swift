import Foundation
import Darwin
import IOKit
import IOKit.ps

/// 系统占用采样:CPU(总体+每核+Top进程)、内存、网络速率、硬盘空间与读写速率、电池
final class SystemStats {
    struct BatteryInfo {
        var present = false
        var percent = 0.0        // 0...100
        var onAC = false
        var charging = false
        var cycleCount = 0
        var health = 0.0         // 0...1(最大容量/设计容量)
        var watts = 0.0          // 实时功率 W
    }

    struct ProcUsage {
        var pid: Int32
        var name: String
        var percent: Double      // 占整机百分比
        var memMB: Double        // 常驻内存
    }

    struct Snapshot {
        let cpuUsage: Double        // 0...1
        let coreUsages: [Double]    // 每核 0...1
        let memTotal: UInt64        // 字节
        let memUsed: UInt64
        let netIn: Double           // B/s
        let netOut: Double
        let diskTotal: UInt64       // 字节(启动卷所在容器)
        let diskUsed: UInt64
        let diskRead: Double        // B/s
        let diskWrite: Double
        let battery: BatteryInfo
        let topProcs: [ProcUsage]
        let topMemProcs: [ProcUsage]
        let gpuUsage: Int?          // GPU 占用 %(Apple Silicon;Intel 无 IOGPUDevice 时为 nil)
        let netInTotal: UInt64      // 网卡累计字节(流量日统计用)
        let netOutTotal: UInt64
    }

    private var lastCoreBusy: [UInt64] = []
    private var lastCoreTotal: [UInt64] = []
    private var lastNetIn: UInt64 = 0
    private var lastNetOut: UInt64 = 0
    private var lastDiskRead: UInt64 = 0
    private var lastDiskWrite: UInt64 = 0
    private var lastProcTimes: [Int32: UInt64] = [:]
    private var lastTime: Date?

    private let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    private let pageSize = UInt64(vm_kernel_page_size)
    private var memTotalCache: UInt64 = 0

    init() {
        var size: size_t = MemoryLayout<UInt64>.size
        var v: UInt64 = 0
        sysctlbyname("hw.memsize", &v, &size, nil, 0)
        memTotalCache = v
    }

    func sample() -> Snapshot {
        let now = Date()
        let hadPrev = lastTime != nil
        let elapsed = max(0.2, now.timeIntervalSince(lastTime ?? now))
        let (busy, total) = sampleCPUTicks()
        var cpuUsage = 0.0
        var coreUsages = [Double](repeating: 0, count: total.count)
        if total.count == lastCoreTotal.count, !total.isEmpty {
            for i in 0..<total.count {
                let dTotal = max(1, total[i] - lastCoreTotal[i])
                let dBusy = min(busy[i] - lastCoreBusy[i], dTotal)
                coreUsages[i] = min(1, Double(dBusy) / Double(dTotal))
            }
            let sumT = total.reduce(0, +) - lastCoreTotal.reduce(0, +)
            let sumB = busy.reduce(0, +) - lastCoreBusy.reduce(0, +)
            if sumT > 0 { cpuUsage = min(1, Double(sumB) / Double(sumT)) }
        }
        lastCoreBusy = busy
        lastCoreTotal = total

        // 内存
        let memUsed = sampleMemoryUsed()

        // 网速
        let (inBytes, outBytes) = sampleNetworkBytes()
        var netIn = 0.0, netOut = 0.0
        if hadPrev {
            netIn = Double(inBytes > lastNetIn ? inBytes - lastNetIn : 0) / elapsed
            netOut = Double(outBytes > lastNetOut ? outBytes - lastNetOut : 0) / elapsed
        }
        lastNetIn = inBytes
        lastNetOut = outBytes

        // 硬盘
        let (diskTotal, diskUsed) = sampleDiskSpace()
        let (readBytes, writeBytes) = sampleDiskBytes()
        var diskRead = 0.0, diskWrite = 0.0
        if hadPrev {
            diskRead = Double(readBytes > lastDiskRead ? readBytes - lastDiskRead : 0) / elapsed
            diskWrite = Double(writeBytes > lastDiskWrite ? writeBytes - lastDiskWrite : 0) / elapsed
        }
        lastDiskRead = readBytes
        lastDiskWrite = writeBytes
        lastTime = now

        let battery = sampleBattery()
        let (topCPU, topMem) = sampleTopProcesses(n: 5, hasPrev: hadPrev, totalCPU: cpuUsage)
        let gpu = sampleGPU()

        return Snapshot(cpuUsage: cpuUsage, coreUsages: coreUsages,
                        memTotal: memTotalCache, memUsed: memUsed,
                        netIn: netIn, netOut: netOut,
                        diskTotal: diskTotal, diskUsed: diskUsed,
                        diskRead: diskRead, diskWrite: diskWrite,
                        battery: battery, topProcs: topCPU, topMemProcs: topMem,
                        gpuUsage: gpu, netInTotal: lastNetIn, netOutTotal: lastNetOut)
    }

    // MARK: - CPU(host_processor_info,每核 user+system+nice 为忙时)

    private func sampleCPUTicks() -> (busy: [UInt64], total: [UInt64]) {
        var count: natural_t = 0
        var infoPtr: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &count, &infoPtr, &infoCount)
        guard kr == KERN_SUCCESS, let info = infoPtr else { return ([], []) }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<Int32>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        let n = Int(count)
        var busy = [UInt64](), total = [UInt64]()
        busy.reserveCapacity(n); total.reserveCapacity(n)
        for i in 0..<n {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            busy.append(user + sys + nice)
            total.append(user + sys + nice + idle)
        }
        return (busy, total)
    }

    // MARK: - 内存(active + wired + 压缩,接近活动监视器口径)

    private func sampleMemoryUsed() -> UInt64 {
        var vm = vm_statistics64_data_t()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let active = UInt64(vm.active_count) * pageSize
        let wired = UInt64(vm.wire_count) * pageSize
        let compressed = UInt64(vm.compressor_page_count) * pageSize
        return active + wired + compressed
    }

    // MARK: - 网络字节(sysctl NET_RT_IFLIST2,64 位计数器;只统计 en*/ppp* 物理接口,避免 utun 重复计数)

    private func sampleNetworkBytes() -> (in: UInt64, out: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let hdr2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let flags = Int32(hdr2.ifm_flags)
                    if flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                       Self.isCountedInterface(index: UInt32(hdr2.ifm_index)) {
                        inBytes += hdr2.ifm_data.ifi_ibytes
                        outBytes += hdr2.ifm_data.ifi_obytes
                    }
                }
                offset += msglen
            }
        }
        return (inBytes, outBytes)
    }

    private static func isCountedInterface(index: UInt32) -> Bool {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        guard if_indextoname(index, &name) != nil else { return false }
        let s = String(cString: name)
        return s.hasPrefix("en") || s.hasPrefix("ppp")
    }

    // MARK: - GPU 占用(Apple Silicon:IOAccelerator 的 PerformanceStatistics)

    private func sampleGPU() -> Int? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        var total = 0
        var count = 0
        var svc = IOIteratorNext(iter)
        while svc != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
            guard let raw = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString,
                                                            kCFAllocatorDefault, 0),
                  let stats = raw.takeRetainedValue() as? [String: Any],
                  let util = stats["Device Utilization %"] as? Int else { continue }
            total += util
            count += 1
        }
        return count > 0 ? total / count : nil
    }

    // MARK: - 电池(IOPowerSources + AppleSmartBattery 注册表)

    private func sampleBattery() -> BatteryInfo {
        var info = BatteryInfo()
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any] else { continue }
                info.present = true
                if let v = desc[kIOPSCurrentCapacityKey as String] as? Int { info.percent = Double(v) }
                if let v = desc[kIOPSIsChargingKey as String] as? Bool { info.charging = v }
                if let v = desc[kIOPSPowerSourceStateKey as String] as? String { info.onAC = (v == kIOPSACPowerValue as String) }
            }
        }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != IO_OBJECT_NULL else { return info }
        defer { IOObjectRelease(svc) }
        func intProp(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        info.cycleCount = intProp("CycleCount") ?? 0
        // Apple Silicon 上 MaxCapacity 是百分数,健康度需用 mAh 口径:实测容量/设计容量
        let measured = intProp("AppleRawMaxCapacity") ?? intProp("NominalChargeCapacity") ?? intProp("MaxCapacity")
        if let maxc = measured, let design = intProp("DesignCapacity"), design > 0 {
            let ratio = Double(maxc) / Double(design)
            if ratio > 0.2 && ratio < 1.05 { info.health = ratio }
        }
        if let amps = intProp("Amperage"), let volts = intProp("Voltage") {
            info.watts = Double(abs(amps)) * Double(volts) / 1_000_000
        }
        return info
    }

    // MARK: - Top CPU 进程(proc_pidinfo 任务耗时差值,按占比分摊总 CPU 占用率)

    private func sampleTopProcesses(n: Int, hasPrev: Bool, totalCPU: Double) -> (cpu: [ProcUsage], mem: [ProcUsage]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return ([], []) }
        let count = size / MemoryLayout<kinfo_proc>.stride
        guard count > 0 else { return ([], []) }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return ([], []) }
        let actual = min(count, size / MemoryLayout<kinfo_proc>.stride)

        var current = [Int32: UInt64]()
        current.reserveCapacity(actual)
        var entries: [(pid: Int32, name: String, delta: UInt64, memMB: Double)] = []
        for i in 0..<actual {
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { continue }
            var pti = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            let total = pti.pti_total_user + pti.pti_total_system
            current[pid] = total
            let name = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw -> String in
                let bytes = raw.prefix(while: { $0 != 0 })
                return String(bytes: bytes, encoding: .utf8) ?? ""
            }
            let memMB = Double(pti.pti_resident_size) / 1_048_576
            let delta: UInt64
            if hasPrev, let prev = lastProcTimes[pid], total > prev {
                delta = total - prev
            } else {
                delta = 0
            }
            entries.append((pid, name.isEmpty ? "pid \(pid)" : name, delta, memMB))
        }
        lastProcTimes = current

        let sum = entries.reduce(UInt64(0)) { $0 + $1.delta }
        var cpuList: [ProcUsage] = []
        if sum > 0, totalCPU > 0.005 {
            cpuList = entries.filter { $0.delta > 0 }
                .sorted { $0.delta > $1.delta }
                .prefix(n)
                .map { ProcUsage(pid: $0.pid, name: $0.name,
                                 percent: Double($0.delta) / Double(sum) * totalCPU * 100,
                                 memMB: $0.memMB) }
        }
        let memList = entries.sorted { $0.memMB > $1.memMB }
            .prefix(n)
            .map { ProcUsage(pid: $0.pid, name: $0.name, percent: 0, memMB: $0.memMB) }
        return (cpuList, memList)
    }

    // MARK: - 硬盘空间(启动卷,"重要用途可用容量"口径与 Finder 一致)

    private func sampleDiskSpace() -> (total: UInt64, used: UInt64) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                              .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let avail = values.volumeAvailableCapacityForImportantUsage else { return (0, 0) }
        let t = UInt64(max(0, total))
        let a = UInt64(max(0, avail))
        return (t, t > a ? t - a : 0)
    }

    // MARK: - 硬盘读写字节(所有 IOBlockStorageDriver 的累计统计)

    private func sampleDiskBytes() -> (read: UInt64, write: UInt64) {
        var iter: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceMatching("IOBlockStorageDriver"), &iter)
        guard kr == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var read: UInt64 = 0, write: UInt64 = 0
        while true {
            let service = IOIteratorNext(iter)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                            kCFAllocatorDefault, 0),
                  let stats = raw.takeRetainedValue() as? [String: Any] else { continue }
            if let n = stats["Bytes (Read)"] as? NSNumber { read += n.uint64Value }
            if let n = stats["Bytes (Write)"] as? NSNumber { write += n.uint64Value }
        }
        return (read, write)
    }
}

extension SystemStats.Snapshot {
    var memPercent: Double {
        memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0
    }

    var diskPercent: Double {
        diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0
    }

    static func speed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        return String(format: "%.0f B/s", max(0, bytesPerSec))
    }

    static func size(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// 硬盘用十进制 GB(与 Finder/磁盘工具一致),大容量不带小数
    static func diskSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1000 { return String(format: "%.2f TB", gb / 1000) }
        if gb >= 100 { return String(format: "%.0f GB", gb) }
        return String(format: "%.1f GB", gb)
    }

    /// 流量累计(十进制)
    static func trafficSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1000)
    }
}
