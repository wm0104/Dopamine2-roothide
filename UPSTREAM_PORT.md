# 上游选择性移植（2026-11-05）

- 定制基线：`a04b04151b37c54a8be29806b6c5da73fe4eeb00`。
- 参考上游：w2599/Dopamine `3.x_roothide_AI_review_fix`，`7e14aa6155ce867e9052a88a8c17c632f4c30d77`。
- 这是部分、明确限定范围的移植，不是整分支合并，也不宣称完成全部解析安全更新。

## 保留的定制

备份/恢复、Filza 文件夹、软件源迁移及自有源、保留份数与旧备份识别、环境版本身份机制和精简 UI 原样保留。`Tests/custom_preservation_manifest.json` 固定 20 个原定制实现/测试文件 SHA256。JailFools、额外 TrollStoreLite TXM/租约、强制 debug 和自定义挂载未恢复。

版本基础更新为3.0.13。独立环境修订从29升30，以便现有安装发现新 basebin；显示版本3.0.13-30，包标识仍cn.zqbb.dopaRH，不增加自定义显示后缀。

## 本次移植

- Dopamine3.0.13基础中的启动属性恢复、消息进程相关RootHide调整、潜在死锁和SpringBoard snapshot hook修复。
- `193086c`、`c15b997`：spawn失败处理、persona/启动属性恢复、fork握手与资源清理。
- `8167d0a`：trustcache跨页追加、内存上界、链表写入失败恢复；保持原签名收集ABI。
- `aa61a30`：配置快照缓存、并发与fork/vfork隔离。
- `8bceb69`：IPC/hookd参数分发和通信边界。
- `23ec561`：进程监听记录回收和任务缓存限制。
- `ad09035`：basebin信任缓存初始化自身错误处理（不使用新的签名收集接口）。
- `7cb89f6`、`302f485`、`7e14aa6`：虚拟内存写入递归修复、killall路径边界、归档路径/错误处理。

## 明确暂缓

|提交|原因|
|---|---|
|`882343e` / ChOma `4e4f8849e7a2025ab1717fe0a214d6363b9c1cc6`|子模块提交在公开来源不可获取：fetch not our ref、commit API422。继续固定原7dccded解析器。|
|`15a0754`|新的签名三态收集、失败传播依赖修正后的底层解析返回契约，不能硬配旧解析器。|
|`845e3a0`|签名回滚/边界测试还依赖底层无效流和fd0清理，无法证明与缺失解析器独立。|

`worker/` 包含原始上游测试以保留证据；`Tests/run_upstream_regressions.py` 明确列出12组已包含套件和4组暂缓套件，不把暂缓项目算作成功。未改断言来让旧解析器假通过。

## 验证及限制

Linux四组真实生产C函数回归通过：trustcache、spawn persona（52故障+3组168重复）、spawn runtime（600 Jetsam等）、launchd errno/PID（12场景），包含mutation反例。iSH不支持ASan影子地址范围，因此Linux使用UBSan，不声称ASan覆盖。Foundation/完整iOS编译、签名和重解包校验由独立测试分支的Mac工作流执行，不能在成功前宣称已完成。未进行越狱真机测试。

上游成功运行41949151826的workflow实际上checkout `roothide/Dopamine-roothide`，不是本参考分支，不能作为本批变更的成功证据。用户正式custom分支保持原样，待测试验收后再更新。
