# Mac 验机助手

面向二手 Mac 收购的本地原生 macOS 应用。拷贝 `.app` 后双击运行；每轮检测独立记录，自动保存，支持 PDF、HTML、JSON 导出。当前为 **0.1.1 预览版**，不是 Apple 认证检测工具，也不能保证机器无故障。

## 运行

[下载安装包](https://github.com/shishirui/Mac-detect/releases/tag/v0.1.1)。

构建产物：`dist/Mac验机助手.app`，或解压 `dist/MacDetect-0.1.1-universal.zip`。

- 目标系统：macOS 13 或更新版本；Universal 二进制包含 arm64、x86_64。
- 无需在目标机安装 Xcode、Homebrew、Python 或其他运行依赖。
- 需要能够登录并运行应用的 macOS。不能在激活锁页面或无法启动系统时直接运行。
- GitHub **v0.1.1 发布包**使用 Developer ID Application 签名并通过 Apple 公证，已附加公证票据。首次运行仍可能出现正常的“从互联网下载的应用”确认框；无需关闭 Gatekeeper 或 SIP。Apple 公证是软件分发安全检查，不是硬件检测能力认证。
- 自行构建且未配置签名 / 公证凭据时，仍会生成 ad-hoc 本地开发包，不能把它当作已公证的发布包。
- 所有自动检测均在本机执行，无遥测、账户、上传或服务器依赖。官方说明链接会在用户点击后打开浏览器。

建议先快速筛查，再根据需要运行标准 / 深度验机，完成“人工检查”，最后导出报告。

## 当前实现

| 功能 | 实际范围 |
| --- | --- |
| 硬件配置 | 从系统读取机型、芯片、CPU 核心、内存和序列号；不保证信息未被系统篡改 |
| 磁盘健康 | `diskutil info -plist /` 基础 SMART、系统 APFS 容器容量 / 可用空间；外置启动不误判内置盘通过 |
| SSD 详细寿命 | **尚未实现**磨损、累计写入和完整介质错误读取，始终明确标为无法验证 |
| 激活锁 | 仅识别系统明确报告的启用 / 关闭值；缺失或未知不作无锁判断 |
| 企业管理 | 只读 `profiles status -type enrollment`；本机未注册不证明云端无归属 |
| 崩溃记录 | 按名称 / 修改时间筛查近 30 天内核崩溃文件，不读取日志正文；不能据此确定硬件故障 |
| 热状态 | `ProcessInfo.thermalState`，不是温度；本版没有传感器温度或风扇转速 |
| CPU | 最多 8 个线程，循环执行多个固定整数向量，并与独立参考值校验 |
| 内存 | 256 MiB 可分配虚拟内存，多种数据模式写入并全部读回；可能分页，不覆盖全部物理内存 |
| GPU | 默认 Metal GPU 的计算任务，每轮抽查，末轮全部读回与 CPU 参考值核对；不覆盖显示接口、全部 GPU 或视频编解码 |
| 磁盘读写 | 独占临时文件、伪随机内容、fsync 后读回并核对 SHA-256；不操作裸盘，不代表全盘检测 |
| 人工清单 | 外观、各接口、网络、蓝牙、声音、唤醒、官方诊断、激活 / 组织释放和维修状态 |
| 留档 | 自动本地保存，报告历史，PDF / HTML / JSON，资产编号及备注 |

快速筛查不启动 CPU、内存、GPU 或磁盘写入测试。标准模式 CPU / 内存 / GPU 各 5 分钟，磁盘最多写入 512 MiB；深度模式 CPU / 内存各 20 分钟、GPU 15 分钟，磁盘最多写入 1 GiB。时间估算另受系统调用、人工操作等影响。

每个负载任务使用独立子进程；可以取消，超时终止。检测到系统严重 / 临界热状态或内存压力事件时停止当前负载。不会绕过系统温控。内核崩溃或整机断电无法靠应用阻止。

## 数据与恢复

- 报告：`~/Library/Application Support/MacDetect/Reports/`（JSON，目录 0700、文件 0600）。
- 磁盘测试目录：`~/Library/Caches/MacDetect/Tests/<随机 UUID>/`，正常结束或从界面停止后删除本次临时目录。
- 如果整机断电、内核崩溃或应用被强制结束，可能残留至多本轮磁盘写入上限的临时文件，可在应用完全退出后删除上述 `Tests` 目录。报告中原“待检测 / 检测中”项目重新读取时会变为已中断。
- 自动保存位于**目标 Mac**，离开前请导出到自己的 U 盘。删除 `.app` 不会删除报告。
- 导出含完整设备序列号和操作人备注；界面默认隐藏大部分序列号。报告不是防篡改证书。
- 不自动抹盘、修复磁盘、解除账户、改变设备管理或执行自动重启。

## 构建与验证

开发环境：完整 Xcode，Swift 5.9+。

```sh
swift test
./scripts/build-app.sh
open 'dist/Mac验机助手.app'
```

仅执行只读快速筛查并输出三种报告（不会启动 GUI 或压力测试）：

```sh
'dist/Mac验机助手.app/Contents/MacOS/MacDetect' --quick-report /tmp/mac-inspection.json
```

该命令会生成指定 JSON，以及同名 HTML、PDF。实际机器序列号会写入这些本地文件，不应上传到代码仓库。

正式分发构建需要 `MACDETECT_SIGN_IDENTITY`（已安装的 Developer ID Application 证书）以及以下任一认证方式：

- `MACDETECT_NOTARY_PROFILE`：已存在的 notarytool 钥匙串配置。
- `MACDETECT_NOTARY_KEY_PATH`、`MACDETECT_NOTARY_KEY_ID`：本机已有的 App Store Connect API 私钥路径与 Key ID；团队 API Key 还需 `MACDETECT_NOTARY_ISSUER_ID`，个人 API Key 不提供 issuer。

在本机安全配置这些环境变量后，执行：

```sh
MACDETECT_REQUIRE_NOTARIZATION=1 ./scripts/build-app.sh
```

构建脚本会校验 Developer ID 和安全时间戳，等待 Apple 返回 `Accepted`，附加并校验票据，通过 Gatekeeper 检查后才生成分发 ZIP。`MACDETECT_REQUIRE_NOTARIZATION=1` 会拒绝缺少签名 / 公证配置的构建。可用 `MACDETECT_OUTPUT_DIR` 指定独立输出目录，保留已发布版本。校验文件使用 ZIP 文件名，可在下载目录执行 `shasum -a 256 -c SHA256SUMS.txt`。

不要把账号、密码、证书私钥或环境变量的实际配置值提交到仓库。公证结果保存在 `.build/notarization/`，不会加入 Git。

## 验收边界

编译和单元测试不能替代真机适配。首次交付的本机验证范围见 `VALIDATION.md`。必须使用实际收购的 Mac mini、不同 macOS 和 Intel 机型继续验证，尤其是已知故障机的检出能力。目前没有完成机型覆盖认证，不应据此单独决定收购。

后续优先项：详细 NVMe 健康数据的机型适配、真实 Mac mini 正常 / 故障样本验收、接口传输辅助、长时间稳定性统计。
