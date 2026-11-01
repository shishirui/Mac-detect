import SwiftUI
import MacDetectCore

struct ResetAssistantView: View {
    @EnvironmentObject var store: AppStore
    @State private var goal: ResetGoal = .quickErase
    @State private var showSteps = false
    private var guide: ResetGuide { ResetGuide.make(goal: goal, hardware: store.resetHost?.hardware ?? .unknown) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("PREPARE FOR THE NEXT OWNER").font(.system(size: 10, weight: .semibold)).tracking(2.4).foregroundStyle(Palette.green)
                Text("从验机，到放心交机。").font(.system(size: 29, weight: .semibold))
                Text("按机型选择重置方式，带走报告，交由 Apple 系统完成认证与抹除。").foregroundStyle(Palette.muted)
            }
            hostCard
            VStack(alignment: .leading, spacing: 16) {
                Text("选择你的目的").font(.system(size: 16, weight: .semibold))
                Picker("操作目的", selection: $goal) {
                    ForEach(ResetGoal.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(guide.title).font(.system(size: 19, weight: .semibold))
                Text(guide.detail).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                if goal == .dfu {
                    Text("辅助机系统：\(store.resetHost.map { "macOS \($0.osMajor)" } ?? "未识别") · 目标 Mac 的型号与 DFU 端口需另行核对。")
                        .font(.system(size: 11)).foregroundStyle(Palette.green)
                }
                DisclosureGroup("查看操作步骤与官方指南", isExpanded: $showSteps) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(index + 1)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.green).frame(width: 22, height: 22).background(Palette.mint, in: Circle())
                                Text(step).font(.system(size: 12)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        ForEach(guide.links, id: \.url) { link in Link(link.title + " ↗", destination: link.url).font(.system(size: 11)) }
                    }.padding(.top, 12)
                }
            }.padding(22).card()
            backupCard
            if goal == .quickErase { preparationCard }
            if let message = store.resetMessage { Label(message, systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Palette.green).lineSpacing(4) }
            postCheckCard
        }
        .task { if store.resetHost == nil { store.refreshResetHost() } }
        .onChange(of: goal) { _ in store.resetPreparation = ResetPreparation(); store.showResetConfirmation = false; showSteps = goal != .quickErase }
        .sheet(isPresented: $store.showResetConfirmation) { confirmation }
    }
    private var hostCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("01  确认当前这台 Mac", systemImage: "desktopcomputer").font(.system(size: 16, weight: .semibold))
                Spacer()
                if store.isResetBusy { ProgressView().controlSize(.small) }
                Button("重新识别本机") { store.refreshResetHost() }.disabled(store.isRunning || store.isResetBusy)
            }
            if let host = store.resetHost {
                Text("\(host.machine.model) · \(host.machine.modelIdentifier) · \(host.hardware.title)").font(.system(size: 15, weight: .medium))
                Text("序列号末 4 位：\(host.machine.serial.suffix(4)) · macOS \(host.osMajor) · 读取于 \(host.capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text(host.routeExplanation).font(.system(size: 12)).foregroundStyle(Palette.green)
                Divider()
                Label(host.activation.summary, systemImage: host.activation.status.symbol).font(.system(size: 12)).foregroundStyle(host.activation.status.color)
                Label(host.management.summary, systemImage: host.management.status.symbol).font(.system(size: 12)).foregroundStyle(host.management.status.color)
                Text("抹除不证明账户与组织归属已解除。状态未知时仍需原主协助；组织设备应由原组织正式释放。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                if let report = store.report, !host.matches(report) {
                    Text("当前所选报告属于其他机器或身份不完整，快速抹除入口已锁定。请先对本机创建新报告。")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                }
            } else {
                Text(store.isResetBusy ? "正在只读识别本机信息…" : "尚未识别本机。恢复 / DFU 指引可先查看，快速抹除入口保持关闭。")
                    .foregroundStyle(Palette.muted)
            }
        }.padding(22).background(Palette.mint.opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
    }
    private var backupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("02  带走验机报告与操作单", systemImage: "externaldrive.badge.checkmark").font(.system(size: 16, weight: .semibold))
            Text("交机包包含 PDF、HTML、可重新导入的 JSON 和离线操作单。请保存到 U 盘或另一台电脑；当前 Mac 的桌面、下载目录和其他内置宗卷都不能代替外部备份。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            if let report = store.report {
                Text("所选记录：\(report.machine.modelIdentifier) · 序列号末 4 位 \(report.machine.serial.suffix(4)) · \(report.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                if report.importedFromReportID != nil { Text("这是导入的历史记录，不是本机当前检测结果。").font(.system(size: 11)).foregroundStyle(.orange) }
            }
            HStack {
                Button("导出交机包…") { store.exportHandoff() }.buttonStyle(.borderedProminent)
                    .disabled(store.report == nil || store.report?.finishedAt == nil || store.isRunning || store.isResetBusy)
                Button("导入交机 JSON…") { store.importHandoff() }.buttonStyle(.bordered).disabled(store.isRunning || store.isResetBusy)
                Button("前往验机工作台") { store.selectedPage = .overview }.buttonStyle(.plain)
            }
            if let receipt = store.resetBackup { Text("本次会话已导出：\(receipt.createdAt.formatted(date: .omitted, time: .standard))。仍需确认文件已带离目标 Mac。").font(.system(size: 11)).foregroundStyle(Palette.green) }
        }.padding(22).card()
    }
    private var preparationCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("03  准备快速清空交机", systemImage: "checklist").font(.system(size: 16, weight: .semibold))
            Toggle("所有者已授权清除，所有需要保留的数据已完成备份", isOn: $store.resetPreparation.authorizedAndBackedUp)
            Toggle("我已将交机包保存到 U 盘或另一台电脑，并确认可以打开", isOn: $store.resetPreparation.reportCopiedOffMac)
            Toggle("我已核实账户与组织归属；需要认证时可请原主输入密码", isOn: $store.resetPreparation.accountsReviewed)
            Toggle("已接通电源、准备网络，并移除无关外置存储设备", isOn: $store.resetPreparation.powerAndAccessoriesReady)
            HStack {
                Text("核对本机序列号末 4 位").font(.system(size: 12))
                TextField("输入末 4 位", text: $store.resetPreparation.serialSuffix).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            Text("抹除范围包含本机所有用户的数据、设置、App 和本地验机报告。软件只打开官方入口，密码和最终抹除确认由你在 Apple 系统界面完成。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            if !store.resetBlockers.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.resetBlockers, id: \.self) { Text("• " + $0).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                }
            }
            Button { store.prepareResetConfirmation() } label: {
                Label("核对后继续…", systemImage: "arrow.right.circle").padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).disabled(!store.resetBlockers.isEmpty)
        }.font(.system(size: 12)).toggleStyle(.checkbox).padding(22).card().disabled(store.isRunning || store.isResetBusy)
    }
    private var postCheckCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("04  交机后的人工核验", systemImage: "person.crop.square.filled.and.at.rectangle").font(.system(size: 16, weight: .semibold))
            Text("抹除后重新复制运行验机助手，导入交机包内的 JSON 即可继续记录。若要保持目标机处于开箱状态，可在另一台 Mac 上导入并记录观察。请先核对报告中的目标机型和序列号。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            if store.report != nil {
                Text(store.report?.resetRecord?.summary ?? "尚未填写交机核验").font(.system(size: 13, weight: .medium))
                ForEach(store.report?.resetRecord?.postChecks ?? ResetRecord().postChecks) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(item.title).fontWeight(.medium)
                            Spacer()
                            Picker("核验状态", selection: Binding(get: { store.report?.resetRecord?.postChecks.first { $0.id == item.id }?.state ?? .unverified }, set: { store.setPostCheck(item.id, state: $0) })) {
                                Text("未验证").tag(ManualState.unverified)
                                Text("人工确认通过").tag(ManualState.passed)
                                Text("发现问题").tag(ManualState.issue)
                            }.labelsHidden().frame(width: 155)
                        }
                        Text(item.instructions).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
                        TextField("观察到的页面、时间、凭证说明（填写结果时必填）", text: Binding(get: { store.report?.resetRecord?.postChecks.first { $0.id == item.id }?.note ?? "" }, set: { store.setPostCheck(item.id, note: $0) }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    }.padding(12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("记录由操作人填写。打开抹掉助理或出现欢迎画面都不能证明无激活锁 / 无组织绑定。抹除前的自动检测结果不会被覆盖；填写后请重新导出留档。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                Button("查看 / 导出更新后的报告") { store.selectedPage = .report }.buttonStyle(.bordered)
            } else {
                Text("先创建验机报告，或导入抹除前保存的交机 JSON。").foregroundStyle(Palette.muted)
            }
        }.font(.system(size: 12)).padding(22).card().disabled(store.isRunning || store.isResetBusy)
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("打开 Apple 系统抹掉助理？", systemImage: "exclamationmark.triangle").font(.system(size: 21, weight: .semibold)).foregroundStyle(.orange)
            if let host = store.resetHost {
                Text("目标：当前这台 \(host.machine.model)\n机型：\(host.machine.modelIdentifier)\n序列号：\(host.machine.serial)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
            }
            Text("继续后会打开 Apple 的系统界面。若你随后在那里确认抹除，本机所有用户的数据、设置和 App 将被清除，本地验机报告也会丢失。请确认交机包已带离这台 Mac。")
                .font(.system(size: 13)).lineSpacing(5)
            Text("软件不收集密码，不自动点击系统确认，也不能自动证明抹除成功。").font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Spacer()
                Button("返回检查", role: .cancel) { store.showResetConfirmation = false }.keyboardShortcut(.cancelAction)
                Button("打开系统抹掉助理") { store.openSystemEraseAssistant() }.buttonStyle(.borderedProminent).tint(.orange)
            }
        }.padding(28).frame(width: 570)
    }
}
