import SwiftUI
import AppKit
import MacDetectCore

private enum Palette {
    static let ink = Color(red: 0.10, green: 0.19, blue: 0.18)
    static let green = Color(red: 0.15, green: 0.42, blue: 0.32)
    static let mint = Color(red: 0.88, green: 0.94, blue: 0.90)
    static let canvas = Color(red: 0.96, green: 0.97, blue: 0.96)
    static let muted = Color(red: 0.43, green: 0.48, blue: 0.47)
    static let line = Color(red: 0.88, green: 0.91, blue: 0.89)
}

extension CheckStatus {
    var color: Color {
        switch self {
        case .passed: return Palette.green
        case .failed: return Color(red: 0.73, green: 0.23, blue: 0.22)
        case .warning: return Color(red: 0.64, green: 0.40, blue: 0.12)
        case .running: return .blue
        default: return Palette.muted
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmStress = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                topbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch store.selectedPage {
                        case .overview: overview
                        case .manual: manualPage
                        case .report: reportPage
                        case .history: historyPage
                        }
                    }.padding(30).frame(maxWidth: 1140).frame(maxWidth: .infinity)
                }.id(store.selectedPage)
            }.background(Palette.canvas)
        }
        .font(.system(size: 13)).foregroundStyle(Palette.ink)
        .tint(Palette.green)
        .alert("开始负载检测？", isPresented: $confirmStress) {
            Button("开始验机") { store.start() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(store.mode.detail)\n\n请保存正在编辑的文件，保持通风并关闭其他重负载应用。测试会发热，风扇可能加速；你可随时停止。只操作专用临时文件，不修复或抹掉磁盘。")
        }
        .alert("操作未完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 28)).foregroundStyle(Color(red: 0.72, green: 0.88, blue: 0.73))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac 验机助手").font(.system(size: 17, weight: .semibold))
                    Text("MAC DETECT").font(.system(size: 9, weight: .medium)).tracking(2.5).opacity(0.5)
                }
            }.padding(.top, 42).padding(.bottom, 42).padding(.horizontal, 24)
            Text("验机空间").font(.system(size: 10, weight: .medium)).tracking(1).opacity(0.45).padding(.horizontal, 26).padding(.bottom, 12)
            ForEach(AppPage.allCases) { page in
                Button {
                    store.selectedPage = page
                    if page == .history { store.reloadHistory() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 16)).frame(width: 20)
                        Text(page.rawValue).font(.system(size: 13, weight: store.selectedPage == page ? .semibold : .regular))
                        Spacer()
                        if page == .manual, let report = store.report {
                            Text("\(report.manual.filter { !$0.isResolved }.count)").font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.12), in: Capsule())
                        }
                    }.padding(.horizontal, 15).padding(.vertical, 13)
                        .background(store.selectedPage == page ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 6)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 0.65, green: 0.85, blue: 0.67)).frame(width: 6, height: 6)
                    Text("本地检测 · 无需账户").font(.system(size: 11))
                }
                Text("检测报告保存在此 Mac\n导出后可带走留档").font(.system(size: 11)).lineSpacing(5).opacity(0.5)
                Divider().overlay(.white.opacity(0.1))
                HStack { Text("预览版 \(appVersion)"); Spacer(); Image(systemName: "externaldrive") }.font(.system(size: 10)).opacity(0.4)
            }.padding(24)
        }
        .foregroundStyle(.white).frame(width: 220).background(Palette.ink)
    }
    private var topbar: some View {
        HStack {
            HStack(spacing: 9) {
                Text("工作空间").foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted.opacity(0.5))
                Text(store.selectedPage.rawValue).fontWeight(.medium)
            }
            Spacer()
            if store.isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.75)
                Text("检测进行中").font(.system(size: 11)).foregroundStyle(Palette.green)
            } else {
                Image(systemName: "lock.shield").font(.system(size: 12)).foregroundStyle(Palette.green)
                Text("数据仅保存在本机").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }.padding(.horizontal, 30).frame(height: 62).background(.white)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
    private func title(_ eyebrow: String, _ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow).font(.system(size: 10, weight: .semibold)).tracking(2.4).foregroundStyle(Palette.green)
            Text(name).font(.system(size: 29, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
    }
    private var overview: some View {
        Group {
            title("INSPECT BEFORE YOU BUY", "每台 Mac，都有据可查。", "从配置核验到稳定性测试，为下一次收购留下清晰的判断依据。")
            machineCard
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label("选择验机模式", systemImage: "slider.horizontal.3").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text("01").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                    ForEach(InspectionMode.allCases) { mode in
                        Button { store.mode = mode } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: store.mode == mode ? "largecircle.fill.circle" : "circle").foregroundStyle(store.mode == mode ? Palette.green : Palette.muted.opacity(0.5)).font(.system(size: 17))
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(mode.title).fontWeight(.semibold); Spacer(); Text(mode.estimate).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                                    Text(mode.detail).font(.system(size: 11)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading).lineSpacing(3)
                                }
                            }.padding(13).frame(maxWidth: .infinity).background(store.mode == mode ? Palette.mint.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.mode == mode ? Palette.green.opacity(0.35) : Palette.line, lineWidth: 1))
                        }.buttonStyle(.plain).disabled(store.isRunning)
                    }
                    if store.isRunning {
                        Button { store.stop() } label: {
                            Label("停止检测", systemImage: "stop.fill").frame(maxWidth: .infinity).padding(.vertical, 12)
                        }.buttonStyle(.plain).foregroundStyle(.white).background(Palette.ink, in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        Button {
                            if store.mode == .quick { store.start() } else { confirmStress = true }
                        } label: {
                            HStack { Spacer(); Image(systemName: "play.fill").font(.system(size: 11)); Text(store.report == nil ? "开始一键验机" : "开始新一轮验机").fontWeight(.semibold); Spacer(); Image(systemName: "arrow.right") }.padding(.vertical, 13).padding(.horizontal, 16)
                        }.buttonStyle(.plain).foregroundStyle(.white).background(Palette.green, in: RoundedRectangle(cornerRadius: 9))
                    }
                    Text("新一轮独立记录，历史报告自动保留。").font(.system(size: 10)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                }.padding(20).card().frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("本次检测概览").font(.system(size: 15, weight: .semibold)); Spacer()
                        Text("02").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                    }
                    if store.isRunning {
                        Text(store.currentCheck?.title ?? "正在准备检测…").font(.system(size: 21, weight: .medium))
                        ProgressView(value: Double(store.finishedCount), total: Double(store.checks.count)).tint(Palette.green)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("\(store.finishedCount) / \(store.checks.count) 项已处理  ·  当前项目 \(Int(context.date.timeIntervalSince(store.currentCheckStarted ?? context.date))) 秒").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    } else {
                        Image(systemName: store.report == nil ? "waveform.path.ecg" : "doc.text.magnifyingglass").font(.system(size: 29, weight: .light)).foregroundStyle(Palette.green).padding(.top, 3)
                        Text(store.report?.verdict ?? "准备好，开始了解这台 Mac。").font(.system(size: 19, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        Text(store.report == nil ? "先快速筛查，再按需做稳定性测试。未知与未完成的项目，会始终清楚标出。" : "自动检测结束后，继续完成接口、官方诊断和交机核验。通过只代表本次覆盖范围内未发现异常。").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5)
                    }
                    HStack(spacing: 0) {
                        metric("已通过", "\(store.report?.passedCount ?? 0)", Palette.green)
                        metric("需复核", "\(store.checks.filter { $0.status == .warning || $0.status == .failed }.count)", .orange)
                        metric("人工完成", "\(store.manualDone)/\(ManualCheck.defaults.count)", Palette.ink)
                    }.padding(.vertical, 12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
                    Divider()
                    Button { store.selectedPage = .manual } label: {
                        HStack { Label("继续人工检查", systemImage: "checklist"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.plain).disabled(store.report == nil)
                    Text("SSD 耐久为厂家估算；累计写入、温度与风扇数据需结合负载和人工检查判断。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                }.padding(20).card().frame(maxWidth: .infinity)
            }
            hardwareMetrics
            automaticResults
            boundaryNote
        }
    }
    private var hardwareMetrics: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("SSD 与散热数据", systemImage: "waveform.path.ecg").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(store.isRunning ? "检测期间采集" : "本次检测快照").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 18) {
                hardwareMetric("额定耐久消耗 · 厂家估算", store.report?.ssdHealth?.enduranceText ?? "未验证", "不是剩余使用年限")
                hardwareMetric("累计主机写入", store.report?.ssdHealth?.writtenText ?? "未验证", "十进制 TB · 不等同 NAND 写入")
                hardwareMetric("SSD 复合温度", store.report?.ssdHealth?.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "未验证", "NVMe SMART 单次快照")
                hardwareMetric("SMC 最近采样最高温", store.report?.sensors?.latest?.temperatures.map(\.value).max().map { String(format: "%.1f°C", $0) } ?? "未验证", "已读取通道 · 不保证是 CPU 温度")
                hardwareMetric("SMC 本轮采样最高温", store.report?.sensors?.temperatures.map(\.maximum).max().map { String(format: "%.1f°C", $0) } ?? "未验证", "详见各通道最低 / 最高记录")
                hardwareMetric("风扇最近采样转速", fanMetric, "仅观察转速 · 不改变风扇控制")
            }
            if let sensors = store.report?.sensors, let date = sensors.latest?.sampledAt {
                TimelineView(.periodic(from: .now, by: 2)) { context in
                    Text("传感器：\(sensors.sampleCount) 次采样 · 最后 \(date.formatted(date: .omitted, time: .standard))" + (store.isRunning && context.date.timeIntervalSince(date) > 12 || sensors.interrupted ? " · 采样未更新，显示历史数据" : ""))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            Text("无法读取会保留为未验证；读到数值不等于散热或寿命已被完整验证。展开下方检测项查看数据来源、时间和限制。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(20).card()
    }
    private var fanMetric: String {
        if store.report?.checks.first(where: { $0.id == "fans" })?.status == .notApplicable { return "无风扇 · 不适用" }
        guard let fans = store.report?.sensors?.latest?.fans, !fans.isEmpty else { return "未验证" }
        return fans.map { "\($0.key) \(Int($0.value)) RPM" }.joined(separator: " / ")
    }
    private func hardwareMetric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var machineCard: some View {
        HStack(spacing: 24) {
            ZStack {
                Circle().fill(.white.opacity(0.45)).frame(width: 140, height: 140)
                Image(systemName: store.machine.model.lowercased().contains("book") ? "laptopcomputer" : "macmini").font(.system(size: 79, weight: .ultraLight)).foregroundStyle(Palette.ink.opacity(0.75)).shadow(color: Palette.ink.opacity(0.12), radius: 8, y: 12)
                Image(systemName: "checkmark.shield.fill").font(.system(size: 22)).foregroundStyle(Palette.green).padding(9).background(.white, in: Circle()).offset(x: 49, y: 39)
            }.frame(width: 158, height: 145)
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.report == nil ? "待检测的 Mac" : store.machine.model).font(.system(size: 23, weight: .semibold))
                        Text(store.report == nil ? "点击开始，自动读取当前电脑配置" : "\(store.machine.modelIdentifier)  ·  \(store.machine.architecture)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Text(store.report == nil ? "等待检测" : store.isRunning ? "正在检测" : store.report!.mode.title).font(.system(size: 10, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 6).background(.white.opacity(0.6), in: Capsule())
                }
                HStack(alignment: .top, spacing: 22) {
                    spec("芯片", store.machine.chip)
                    spec("内存", store.machine.memory)
                    spec("系统盘容量", store.machine.storage)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("序列号").font(.system(size: 10)).foregroundStyle(Palette.muted)
                            Button { store.showSerial.toggle() } label: { Image(systemName: store.showSerial ? "eye.slash" : "eye").font(.system(size: 10)) }.buttonStyle(.plain)
                        }
                        Text(store.serialDisplay).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.mint, in: RoundedRectangle(cornerRadius: 15))
    }
    private func spec(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 10)).foregroundStyle(Palette.muted); Text(value).font(.system(size: 13, weight: .semibold)).textSelection(.enabled) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 7) { Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).foregroundStyle(color); Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity)
    }
    private var automaticResults: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("自动检测项目").font(.system(size: 16, weight: .semibold)); Spacer()
                Text("\(store.checks.count) 项 · 点击查看检测依据").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            VStack(spacing: 0) {
                ForEach(store.checks) { check in
                    CheckRow(check: check)
                    if check.id != store.checks.last?.id { Divider().padding(.horizontal, 18) }
                }
            }.card()
        }
    }
    private var manualPage: some View {
        Group {
            title("HANDS-ON VERIFICATION", "把最后一公里，检查到位。", "接口要实际插拔，声音要实际听到，账户和管理绑定要完成交机核验。")
            if let report = store.report {
                HStack(spacing: 16) {
                    Image(systemName: "checklist").font(.system(size: 27)).foregroundStyle(Palette.green)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(store.manualDone) / \(report.manual.count) 项已记录").font(.system(size: 17, weight: .semibold))
                        Text("状态由你填写并自动保存在本机。“不适用”或“发现问题”须填写原因。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Link("Apple 官方诊断指南 ↗", destination: URL(string: "https://support.apple.com/zh-cn/102550")!).font(.system(size: 11))
                }.padding(22).background(Palette.mint, in: RoundedRectangle(cornerRadius: 12))
                ForEach(report.manual) { check in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Image(systemName: check.state == .passed ? "checkmark.circle.fill" : check.state == .issue ? "exclamationmark.triangle.fill" : "circle.dashed").font(.system(size: 18)).foregroundStyle(check.state == .issue ? .orange : Palette.green)
                            Text(check.title).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            Picker("状态", selection: Binding(get: { store.report?.manual.first { $0.id == check.id }?.state ?? .unverified }, set: { store.setManual(check.id, state: $0) })) {
                                ForEach(ManualState.allCases, id: \.self) { state in Text(state.title).tag(state) }
                            }.labelsHidden().frame(width: 160)
                        }
                        Text(check.instructions).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        TextField(check.requiresNote ? "请记录原因、问题或诊断代码（必填）" : "端口位置、诊断代码、核验凭证或备注…", text: Binding(get: { store.report?.manual.first { $0.id == check.id }?.note ?? "" }, set: { store.setManual(check.id, note: $0) }), axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 12)).padding(10).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 7)).lineLimit(1...5)
                        if check.requiresNote && !check.isResolved { Text("补充原因后，此项才算完成记录。").font(.system(size: 10)).foregroundStyle(.orange) }
                    }.padding(20).card()
                }
                boundaryNote
            } else { emptyState("先创建一份验机记录", "在验机工作台开始快速筛查，然后记录人工检查结果。", "checklist") }
        }
    }
    private var reportPage: some View {
        Group {
            title("A RECORD YOU CAN KEEP", "每次检查，都有记录。", "报告保留检测依据、未验证项目与人工备注，方便收购留档和复查。")
            if let report = store.report {
                VStack(alignment: .leading, spacing: 16) {
                    Label(report.verdict, systemImage: report.hasIssue ? "exclamationmark.octagon" : "doc.text.magnifyingglass").font(.system(size: 21, weight: .semibold)).foregroundStyle(report.hasIssue ? Color.red : Palette.ink)
                    Text("\(report.mode.title) · \(report.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(report.passedCount)/\(report.checks.count) 个自动项目通过").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Divider()
                    HStack {
                        ForEach(ExportType.allCases, id: \.self) { format in
                            Button { store.export(format) } label: { Label("导出 \(format.rawValue.uppercased())", systemImage: "square.and.arrow.up").padding(.horizontal, 10).padding(.vertical, 7) }.buttonStyle(.bordered).disabled(store.isRunning)
                        }
                        Spacer()
                    }
                    Text(store.isRunning ? "自动检测进行中，结束或停止后可导出。" : "导出含完整序列号。此报告为本地检测记录，不是 Apple 认证或防篡改鉴定证书。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.padding(24).card()
                machineCard
                VStack(alignment: .leading, spacing: 14) {
                    Text("收购记录").font(.system(size: 16, weight: .semibold))
                    TextField("资产 / 批次编号（可选）", text: Binding(get: { store.report?.assetTag ?? "" }, set: { store.setAssetTag($0) })).textFieldStyle(.roundedBorder)
                    TextField("卖家描述、配置差异、复测情况或收购备注…", text: Binding(get: { store.report?.notes ?? "" }, set: { store.setNotes($0) }), axis: .vertical).textFieldStyle(.plain).padding(12).frame(minHeight: 75, alignment: .top).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8)).lineLimit(3...8)
                }.padding(22).card()
                automaticResults
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("人工核验摘要").font(.system(size: 16, weight: .semibold)); Spacer(); Button("前往填写 →") { store.selectedPage = .manual }.buttonStyle(.plain) }
                    ForEach(report.manual) { item in
                        HStack { Text(item.title); Spacer(); Text(item.isResolved ? item.state.title : "未完成验证").foregroundStyle(item.state == .issue ? .red : item.isResolved ? Palette.green : Palette.muted) }.font(.system(size: 12)).padding(.vertical, 5)
                    }
                }.padding(22).card()
                boundaryNote
            } else { emptyState("还没有验机报告", "完成一次检测后，即可导出 PDF、HTML 或 JSON。", "doc.text") }
        }
    }
    private var historyPage: some View {
        Group {
            title("YOUR INSPECTION LOG", "留存依据，方便再看。", "这里是保存在当前 Mac 的报告。要带走记录，请在离开目标电脑前导出。")
            HStack { Text("\(store.history.count) 份本地报告").foregroundStyle(Palette.muted); Spacer(); Button("打开报告文件夹") { store.revealReports() }.buttonStyle(.bordered) }
            if store.history.isEmpty { emptyState("从第一次验机开始", "检测结果将自动保存在本机，关闭应用后仍可查阅。", "clock.arrow.circlepath") }
            ForEach(store.history) { report in
                Button { store.load(report) } label: {
                    HStack(spacing: 18) {
                        Image(systemName: "desktopcomputer").font(.system(size: 27, weight: .light)).foregroundStyle(Palette.green).frame(width: 46)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("\(report.machine.model) · \(report.machine.chip)").font(.system(size: 16, weight: .medium))
                            Text("\(report.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(report.mode.title) · \(report.id.uuidString.prefix(8))").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Text(report.verdict).font(.system(size: 12)).foregroundStyle(report.hasIssue ? .red : Palette.muted)
                        }
                        Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(Palette.green)
                    }.padding(22).card()
                }.buttonStyle(.plain).disabled(store.isRunning)
            }
        }
    }
    private func emptyState(_ name: String, _ message: String, _ symbol: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Palette.green)
            Text(name).font(.system(size: 20, weight: .medium))
            Text(message).foregroundStyle(Palette.muted)
            Button("返回验机工作台") { store.selectedPage = .overview }.buttonStyle(.borderedProminent).padding(.top, 6)
        }.frame(maxWidth: .infinity).padding(.vertical, 80).card()
    }
    private var boundaryNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Palette.muted)
            Text(InspectionReport.limitations).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
        }.padding(.vertical, 4)
    }
}

private struct CheckRow: View {
    let check: CheckResult
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 13) {
                    Image(systemName: check.status.symbol).font(.system(size: 17)).foregroundStyle(check.status.color).frame(width: 23)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 9) { Text(check.title).font(.system(size: 13, weight: .medium)); Text(check.category.rawValue).font(.system(size: 9)).foregroundStyle(Palette.muted).padding(.horizontal, 6).padding(.vertical, 2).background(Palette.canvas, in: Capsule()) }
                        Text(check.summary).font(.system(size: 11)).foregroundStyle(Palette.muted).multilineTextAlignment(.leading).lineSpacing(3)
                    }
                    Spacer(minLength: 10)
                    Text(check.status.title).font(.system(size: 11, weight: .medium)).foregroundStyle(check.status.color)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }.padding(17).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if check.evidence.isEmpty { Text("检测完成后，将在此显示依据与检测边界。").foregroundStyle(Palette.muted) }
                    ForEach(Array(check.evidence.enumerated()), id: \.offset) { _, line in Text("• \(line)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if let elapsed = check.elapsed { Text("项目耗时：\(String(format: "%.1f", elapsed)) 秒").foregroundStyle(Palette.muted) }
                }.font(.system(size: 11)).lineSpacing(4).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 17).padding(.bottom, 17)
            }
        }
    }
}
private extension View {
    func card() -> some View {
        self.background(.white, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.line.opacity(0.8), lineWidth: 1))
    }
}
