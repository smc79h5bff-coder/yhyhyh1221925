/// web 上拿不到进程 RSS，返回 null，调用方跳过内存监控，
/// 只依赖输入大小和规模上限。
int? currentRssBytes() => null;
