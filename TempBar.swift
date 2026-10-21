// TempBar — แสดงอุณหภูมิ CPU/GPU และรอบพัดลม บน menu bar และ Touch Bar (Intel Mac)
import Cocoa
import IOKit

// MARK: - SMC

struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func fourCCString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        return (r == kIOReturnSuccess && output.result == 0) ? output : nil
    }

    // ชนิดข้อมูลและขนาดของ key (เช่น "flt ", 4)
    func info(_ key: String) -> (type: String, size: Int)? {
        var input = SMCParam()
        input.key = fourCC(key)
        input.data8 = 9
        guard let out = call(&input), out.keyInfo.dataSize > 0 else { return nil }
        return (fourCCString(out.keyInfo.dataType), Int(out.keyInfo.dataSize))
    }

    func read(_ key: String) -> Double? {
        var input = SMCParam()
        input.key = fourCC(key)
        input.data8 = 9 // read key info
        guard let info = call(&input), info.keyInfo.dataSize > 0 else { return nil }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5 // read bytes
        guard let out = call(&input) else { return nil }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        switch fourCCString(info.keyInfo.dataType) {
        case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "flt " where b.count >= 4: return Double(b.withUnsafeBytes { $0.load(as: Float32.self) })
        case "ui8 " where b.count >= 1: return Double(b[0])
        case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        default: return nil
        }
    }

    // อ่านค่าจาก key แรกที่มีและสมเหตุสมผล
    func first(_ keys: [String], range: ClosedRange<Double>) -> Double? {
        for k in keys { if let v = read(k), range.contains(v) { return v } }
        return nil
    }
}

// MARK: - Readings

struct Reading {
    var cpu: Double?
    var gpu: Double?
    var fans: [Double] = []
    var cpuUsage: Double?
    var ramUsage: Double?
}

// MARK: - CPU / RAM usage

final class UsageSampler {
    private var prev: host_cpu_load_info?

    // % CPU ทั้งเครื่อง เทียบกับรอบที่แล้ว
    func cpu() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        defer { prev = info }
        guard let p = prev else { return nil }
        let t = info.cpu_ticks, o = p.cpu_ticks
        let user = Double(t.0 &- o.0), sys = Double(t.1 &- o.1), idle = Double(t.2 &- o.2), nice = Double(t.3 &- o.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total * 100 : nil
    }

    // % RAM ที่ใช้ (app + wired + compressed แบบ Activity Monitor)
    func ram() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            + Double(stats.wire_count) + Double(stats.compressor_page_count)
        return pages * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory) * 100
    }
}

func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "--" }

// MARK: - History graph

final class HistoryView: NSView {
    static let capacity = 300 // 300 × 2 วินาที = 10 นาที
    var temps: [Double?] = []
    var usages: [Double?] = []

    func push(temp: Double?, usage: Double?) {
        temps.append(temp); usages.append(usage)
        if temps.count > Self.capacity { temps.removeFirst(); usages.removeFirst() }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let pad: CGFloat = 14
        let plot = NSRect(x: pad + 22, y: 18, width: bounds.width - pad * 2 - 22, height: bounds.height - 40)
        let labelFont = NSFont.systemFont(ofSize: 9)
        let dim: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]

        // หัวกราฟ
        let maxT = temps.compactMap { $0 }.max(), avgT = temps.compactMap { $0 }.average
        NSAttributedString(string: "ย้อนหลัง 10 นาที   สูงสุด \(fmt(maxT))C   เฉลี่ย \(fmt(avgT))C", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]).draw(at: NSPoint(x: pad, y: bounds.height - 18))

        // เส้นตาราง 0–100
        for v in stride(from: 0, through: 100, by: 25) {
            let y = plot.minY + plot.height * CGFloat(v) / 100
            NSColor.separatorColor.setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.5; line.stroke()
            NSAttributedString(string: "\(v)", attributes: dim).draw(at: NSPoint(x: pad, y: y - 6))
        }

        func path(_ values: [Double?]) -> NSBezierPath {
            let p = NSBezierPath(); var started = false
            let step = plot.width / CGFloat(Self.capacity - 1)
            let offset = Self.capacity - values.count
            for (i, v) in values.enumerated() {
                guard let v else { started = false; continue }
                let pt = NSPoint(x: plot.minX + CGFloat(i + offset) * step,
                                 y: plot.minY + plot.height * CGFloat(min(max(v, 0), 100)) / 100)
                if started { p.line(to: pt) } else { p.move(to: pt); started = true }
            }
            p.lineWidth = 1.5; p.lineJoinStyle = .round
            return p
        }

        NSColor.systemBlue.withAlphaComponent(0.7).setStroke(); path(usages).stroke()
        color(for: temps.last ?? nil).setStroke(); path(temps).stroke()

        // คำอธิบายเส้น
        var x = plot.minX
        for (name, c) in [("อุณหภูมิ CPU (°C)", color(for: temps.last ?? nil)), ("การใช้ CPU (%)", NSColor.systemBlue)] {
            c.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
            let s = NSAttributedString(string: name, attributes: dim)
            s.draw(at: NSPoint(x: x + 11, y: 2)); x += s.size().width + 24
        }
    }
}

// MARK: - Heat alarm

final class HeatAlarm {
    static let choices: [Double] = [65, 70, 75, 80, 85, 90, 95]
    static let hysteresis = 3.0        // ต้องเย็นลงต่ำกว่า threshold - 3 ก่อนถึงจะเตือนรอบใหม่ทันที
    static let repeatEvery: TimeInterval = 60

    private let key = "alarmEnabled"
    private let thresholdKey = "alarmThreshold"

    var threshold: Double {
        get { UserDefaults.standard.object(forKey: thresholdKey) as? Double ?? 80 }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey); lastBeep = nil }
    }
    private var lastBeep: Date?
    private lazy var sound = NSSound(data: Self.beepWAV())

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key); if !newValue { sound?.stop() } }
    }

    // เรียกทุกรอบ refresh: บี๊บเมื่อร้อนเกินครั้งแรก และซ้ำทุก 60 วินาทีถ้ายังร้อนอยู่
    func check(_ temp: Double?) {
        guard let temp else { return }
        if temp < threshold - Self.hysteresis { lastBeep = nil; return }
        guard enabled, temp > threshold else { return }
        if let last = lastBeep, Date().timeIntervalSince(last) < Self.repeatEvery { return }
        lastBeep = Date()
        play()
    }

    func play() {
        sound?.stop()
        sound?.play()
    }

    // เสียง บี๊บ-บี๊บ-บี๊บ 1.8 kHz (สร้างเป็น WAV ในหน่วยความจำ)
    static func beepWAV() -> Data {
        let rate = 44_100, freq = 1_800.0
        var samples: [Int16] = []
        for _ in 0..<3 {
            let on = Int(Double(rate) * 0.12), off = Int(Double(rate) * 0.08)
            for i in 0..<on {
                let fade = min(1, Double(min(i, on - i)) / 200) // กันเสียงคลิก
                samples.append(Int16(sin(2 * .pi * freq * Double(i) / Double(rate)) * 0.6 * fade * 32_767))
            }
            samples += Array(repeating: 0, count: off)
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return d
    }
}

extension Array where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}

let cpuKeys = ["TC0F", "TCXC", "TC0D", "TC0E", "TC0P", "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D"] // Intel ก่อน แล้วค่อย Apple Silicon
let gpuKeys = ["TCGC", "TG0D", "TG0P", "TGDD", "Tg05", "Tg0D", "Tg0f", "Tg0j"]
let tempRange: ClosedRange<Double> = 1...130

func sample(_ smc: SMC) -> Reading {
    var r = Reading()
    r.cpu = smc.first(cpuKeys, range: tempRange)
    r.gpu = smc.first(gpuKeys, range: tempRange)
    let count = Int(smc.read("FNum") ?? 0)
    for i in 0..<count { if let rpm = smc.read("F\(i)Ac") { r.fans.append(rpm) } }
    return r
}

func color(for t: Double?) -> NSColor {
    guard let t else { return .secondaryLabelColor }
    switch t {
    case ..<60: return .systemGreen
    case ..<80: return .systemOrange
    default: return .systemRed
    }
}

func fmt(_ t: Double?) -> String { t.map { "\(Int($0.rounded()))°" } ?? "--" }

// MARK: - Touch Bar private API (DFRFoundation)

let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

func setControlStripPresence(_ id: NSTouchBarItem.Identifier, _ present: Bool) {
    guard let sym = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
    typealias F = @convention(c) (CFString, Bool) -> Void
    unsafeBitCast(sym, to: F.self)(id.rawValue as CFString, present)
}

func showCloseBox(_ show: Bool) {
    guard let sym = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
    typealias F = @convention(c) (Bool) -> Void
    unsafeBitCast(sym, to: F.self)(show)
}

extension NSTouchBarItem {
    static func addSystemTray(_ item: NSTouchBarItem) {
        let sel = Selector(("addSystemTrayItem:"))
        if NSTouchBarItem.responds(to: sel) { NSTouchBarItem.perform(sel, with: item) }
    }
}

extension NSTouchBar {
    static func presentSystemModal(_ bar: NSTouchBar, trayID: NSTouchBarItem.Identifier) {
        let sel = Selector(("presentSystemModalTouchBar:systemTrayItemIdentifier:"))
        let legacy = Selector(("presentSystemModalFunctionBar:systemTrayItemIdentifier:"))
        if NSTouchBar.responds(to: sel) { NSTouchBar.perform(sel, with: bar, with: trayID.rawValue) }
        else if NSTouchBar.responds(to: legacy) { NSTouchBar.perform(legacy, with: bar, with: trayID.rawValue) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    let trayID = NSTouchBarItem.Identifier("com.atom.tempbar.tray")
    let detailIDs = (cpu: NSTouchBarItem.Identifier("com.atom.tempbar.cpu"),
                     gpu: NSTouchBarItem.Identifier("com.atom.tempbar.gpu"),
                     fan: NSTouchBarItem.Identifier("com.atom.tempbar.fan"),
                     usage: NSTouchBarItem.Identifier("com.atom.tempbar.usage"),
                     alarm: NSTouchBarItem.Identifier("com.atom.tempbar.alarm"))

    var smc: SMC!
    let usage = UsageSampler()
    let history = HistoryView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
    let usageLabel = NSTextField(labelWithString: "CPU -- RAM --")
    let menuUsage = NSMenuItem()
    let alarm = HeatAlarm()
    let menuAlarm = NSMenuItem(title: "", action: #selector(toggleAlarm), keyEquivalent: "")
    let menuThreshold = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let alarmButton = NSButton(title: "", target: nil, action: nil)
    var statusItem: NSStatusItem!
    let trayButton = NSButton(title: "--", target: nil, action: nil)
    let cpuLabel = NSTextField(labelWithString: "CPU --")
    let gpuLabel = NSTextField(labelWithString: "GPU --")
    let fanLabel = NSTextField(labelWithString: "Fan --")
    var detailBar: NSTouchBar!
    let menuCPU = NSMenuItem(), menuGPU = NSMenuItem(), menuFan = NSMenuItem()

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let smc = SMC() else {
            let a = NSAlert(); a.messageText = "เปิด AppleSMC ไม่ได้"; a.runModal(); NSApp.terminate(nil); return
        }
        self.smc = smc
        setupMenuBar()
        setupTouchBar()
        refresh()
        // .common ให้ยังอัปเดตตอนเปิดเมนูค้างไว้
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)

        // ใช้ตอนอัดภาพ README: สั่งเปิด/ปิดเมนูและหน้ารายละเอียด Touch Bar จากภายนอก
        let dnc = DistributedNotificationCenter.default()
        let demo: [(String, (AppDelegate) -> Void)] = [
            ("menu", { $0.statusItem.button?.performClick(nil) }),
            ("close", { $0.statusItem.menu?.cancelTracking() }),
            ("touchbar", { $0.showDetail() }),
        ]
        for (name, action) in demo {
            dnc.addObserver(forName: .init("com.atom.tempbar.demo.\(name)"), object: nil, queue: .main) { [weak self] _ in
                if let self { action(self) }
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        for item in [menuCPU, menuGPU, menuFan, menuUsage] { item.isEnabled = false; menu.addItem(item) }
        menu.addItem(.separator())
        let graph = NSMenuItem(); graph.view = history
        menu.addItem(graph)
        menu.addItem(.separator())
        menuAlarm.target = self
        menu.addItem(menuAlarm)
        let sub = NSMenu()
        for t in HeatAlarm.choices {
            let item = NSMenuItem(title: "\(Int(t))°C", action: #selector(pickThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(t)
            sub.addItem(item)
        }
        menuThreshold.submenu = sub
        menu.addItem(menuThreshold)
        let test = NSMenuItem(title: "ทดสอบเสียงเตือน", action: #selector(testAlarm), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "ออกจาก TempBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func setupTouchBar() {
        trayButton.target = self
        trayButton.action = #selector(showDetail)
        trayButton.bezelColor = .clear
        let tray = NSCustomTouchBarItem(identifier: trayID)
        tray.view = trayButton
        NSTouchBarItem.addSystemTray(tray)
        setControlStripPresence(trayID, true)

        detailBar = NSTouchBar()
        detailBar.delegate = self
        detailBar.defaultItemIdentifiers = [detailIDs.cpu, .fixedSpaceLarge, detailIDs.gpu, .fixedSpaceLarge,
                                            detailIDs.usage, .fixedSpaceLarge, detailIDs.fan, .flexibleSpace, detailIDs.alarm]
        for l in [cpuLabel, gpuLabel, fanLabel, usageLabel] { l.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold) }
        alarmButton.target = self
        alarmButton.action = #selector(toggleAlarm)
        updateAlarmUI()
    }

    @objc func toggleAlarm() {
        alarm.enabled.toggle()
        updateAlarmUI()
    }

    @objc func testAlarm() { alarm.play() }

    func updateAlarmUI() {
        let t = Int(alarm.threshold)
        menuAlarm.title = "เสียงเตือนเมื่อเกิน \(t)°C"
        menuAlarm.state = alarm.enabled ? .on : .off
        menuThreshold.title = "ตั้งอุณหภูมิเตือน: \(t)°C"
        menuThreshold.submenu?.items.forEach { $0.state = $0.tag == t ? .on : .off }
        alarmButton.title = alarm.enabled ? "🔔 เตือน \(t)°" : "🔕 ปิดเสียง"
    }

    @objc func pickThreshold(_ sender: NSMenuItem) {
        alarm.threshold = Double(sender.tag)
        updateAlarmUI()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: id)
        switch id {
        case detailIDs.cpu: item.view = cpuLabel
        case detailIDs.gpu: item.view = gpuLabel
        case detailIDs.fan: item.view = fanLabel
        case detailIDs.usage: item.view = usageLabel
        case detailIDs.alarm: item.view = alarmButton
        default: return nil
        }
        return item
    }

    @objc func showDetail() {
        showCloseBox(true)
        NSTouchBar.presentSystemModal(detailBar, trayID: trayID)
    }

    func refresh() {
        var r = sample(smc)
        r.cpuUsage = usage.cpu()
        r.ramUsage = usage.ram()
        history.push(temp: r.cpu, usage: r.cpuUsage)
        alarm.check(r.cpu)
        let fanText = r.fans.isEmpty ? "--" : r.fans.map { "\(Int($0))" }.joined(separator: " / ") + " rpm"

        // menu bar: "CPU 62° 23%  RAM 61%"
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
        let num: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]
        let title = NSMutableAttributedString(string: "CPU ", attributes: small)
        title.append(NSAttributedString(string: "\(fmt(r.cpu)) \(pct(r.cpuUsage))", attributes: num))
        title.append(NSAttributedString(string: "  RAM ", attributes: small))
        title.append(NSAttributedString(string: pct(r.ramUsage), attributes: num))
        statusItem.button?.attributedTitle = title

        menuCPU.title = "CPU: \(fmt(r.cpu))C  ใช้งาน \(pct(r.cpuUsage))"
        menuGPU.title = "GPU: \(fmt(r.gpu))C"
        menuFan.title = "พัดลม: \(fanText)"
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        menuUsage.title = "RAM: \(pct(r.ramUsage)) ของ \(Int(totalGB.rounded())) GB"

        // Touch Bar control strip: "62°" สีตามความร้อน (ช่องแคบ ใส่ได้แค่นี้)
        trayButton.attributedTitle = NSAttributedString(string: fmt(r.cpu), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: color(for: r.cpu),
        ])
        usageLabel.stringValue = "⚙︎ \(pct(r.cpuUsage))  ▦ RAM \(pct(r.ramUsage))"

        cpuLabel.stringValue = "CPU \(fmt(r.cpu))C"; cpuLabel.textColor = color(for: r.cpu)
        gpuLabel.stringValue = "GPU \(fmt(r.gpu))C"; gpuLabel.textColor = color(for: r.gpu)
        fanLabel.stringValue = "🌀 \(fanText)"
    }
}

if CommandLine.arguments.contains("--beep") {
    let s = NSSound(data: HeatAlarm.beepWAV())
    print("beep sound loaded:", s != nil, "duration:", s?.duration ?? 0)
    s?.play(); sleep(1)
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    // debug: แสดงค่าที่อ่านได้แล้วจบ
    guard let smc = SMC() else { print("open SMC failed"); exit(1) }
    print("struct stride:", MemoryLayout<SMCParam>.stride)
    for k in cpuKeys + gpuKeys + ["TC1C", "TC2C", "TC3C", "TC4C", "FNum", "FS! ", "Ftst"]
        + (0..<2).flatMap({ i in ["Ac", "Mn", "Mx", "Tg", "Md"].map { "F\(i)\($0)" } }) {
        print(k, smc.info(k).map { "[\($0.type)]" } ?? "", smc.read(k).map { String(format: "%.1f", $0) } ?? "-")
    }
    let u = UsageSampler(); _ = u.cpu(); sleep(1)
    print("CPU usage", pct(u.cpu()), "RAM", pct(u.ram()))
    if let i = CommandLine.arguments.firstIndex(of: "--dump"), i + 1 < CommandLine.arguments.count {
        // render กราฟจากค่าจริง 20 วินาที ลงไฟล์ png
        let v = HistoryView(frame: NSRect(x: 0, y: 0, width: 320, height: 150)); v.appearance = NSAppearance(named: .aqua)
        for _ in 0..<20 { v.push(temp: smc.first(cpuKeys, range: tempRange), usage: u.cpu()); usleep(1_000_000) }
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
