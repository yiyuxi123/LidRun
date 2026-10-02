import Darwin

// NET_RT_IFLIST2 publishes if_data64 counters. getifaddrs uses the older
// if_data layout, whose byte counters wrap every 4 GiB on macOS.
func readPhysicalNetwork64() -> [String: (received: UInt64, sent: UInt64)]? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]

    // An interface can appear between the size query and the read. Retry only
    // that bounded race; other sysctl failures let the caller use its fallback.
    for _ in 0..<3 {
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0,
              length >= 0, length <= 16 * 1024 * 1024 else { return nil }
        if length == 0 { return [:] }

        var storage = [UInt8](repeating: 0, count: length)
        var used = length
        let result = storage.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &used, nil, 0)
        }
        if result != 0 {
            if errno == ENOMEM { continue }
            return nil
        }
        guard used >= 0, used <= storage.count else { return nil }

        return storage.withUnsafeBytes { bytes in
            var counters: [String: (received: UInt64, sent: UInt64)] = [:]
            var offset = 0
            while offset < used {
                // All routing messages share length/version/type in their
                // first four bytes. Address messages need only be skipped.
                guard used - offset >= 4 else { return nil }
                let messageLength = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                let version = bytes[offset + 2]
                let type = bytes[offset + 3]
                guard messageLength >= 4, messageLength <= used - offset,
                      version == UInt8(RTM_VERSION) else { return nil }

                if type == UInt8(RTM_IFINFO2) {
                    guard messageLength >= MemoryLayout<if_msghdr2>.size else { return nil }
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    guard header.ifm_index != 0 else { return nil }
                    var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    guard if_indextoname(UInt32(header.ifm_index), &nameBuffer) != nil else { return nil }
                    let name = String(cString: nameBuffer)
                    if name.hasPrefix("en"), header.ifm_flags & IFF_LOOPBACK == 0 {
                        counters[name] = (header.ifm_data.ifi_ibytes, header.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
            return counters
        }
    }
    return nil
}
