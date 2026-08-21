# NTP 自动点击器

基于 ntpd 算法高精度时间同步的 Windows 自动点击工具，在指定时刻、指定坐标执行批量鼠标点击。

## 功能

- **NTP 时间同步（ntpd 算法移植）** — 6 源池（Cloudflare / Google / Apple / 阿里云 / NTP Pool CN / Windows）并行查询，每源 8 样本 min-RTT 时钟滤波，Marzullo 区间交集剔除 falseticker，PLL/FLL 频率纪律修正长期漂移。启动自动同步 + 手动「同步」按钮，无后台周期重同步。
- **定时点击** — 按年/月/日/时/分/秒/毫秒设定目标时刻触发，毫秒级精度。
- **批量连击** — 可设点击次数（1~任意）与间隔（≥2ms）。
- **坐标拾取** — 按 F6 实时捕获鼠标位置。
- **测试点击** — 不等待定时，立即执行一次，验证坐标与参数。
- **点击偏移** — 支持比目标时间提前或延后指定毫秒触发。

## 使用

1. 启动程序，自动开始 NTP 同步（也可手动点「同步」）。
2. 同步完成后界面显示所选源、不确定度、延迟、stratum。
3. 设置目标日期与时间。
4. 拾取或手动输入点击坐标。
5. 设置点击次数和间隔。
6. 点「启动定时点击」，程序在目标时刻自动执行。

## 构建

```bash
flutter pub get
flutter build windows --release
```

可执行文件生成在 `build\windows\x64\runner\Release\autoclick.exe`。

或直接从 [Releases](https://github.com/CTL-XG/autoclick/releases) 下载已构建的 `autoclick-windows-<version>.zip`。

## CI / 发版

- **daily_build** — 推送到 `main` 自动跑 `flutter analyze` + `test` + `build windows`，上传构建产物（临时 artifact）。
- **release** — 打 `v*` tag 自动构建 + 创建 GitHub Release + 挂版本化 zip：

  ```bash
  git tag v1.0.0
  git push origin v1.0.0
  ```

## 依赖

- Flutter SDK ^3.12
- [ffi](https://pub.dev/packages/ffi) — Windows API 调用（user32.dll）
- [meta](https://pub.dev/packages/meta) — `@visibleForTesting`

## 许可证

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
