# NTP 自动点击器

基于 NTP 高精度时间同步的 Windows 自动点击工具，支持在指定时间、指定坐标执行批量鼠标点击。

## 功能

- **NTP 时间同步** — 从阿里云 / 中国 NTP 服务器获取精确时间，5 次采样 + 离群值剔除，RTT 质量门控（>80ms 拒绝），确保时间基准准确
- **定时点击** — 按设定的年/月/日/时/分/秒/毫秒触发点击，支持毫秒级精度
- **批量连击** — 可设定点击次数（1~任意）和间隔（≥2ms）
- **坐标拾取** — 按 F6 键实时捕获当前鼠标位置
- **测试点击** — 在不等待定时触发的情况下立即执行点击，验证坐标和参数
- **点击偏移** — 支持比目标时间提前或延后指定毫秒数触发

## 使用

1. 启动程序，选择 NTP 服务器，点击「同步」
2. 等待同步完成（状态指示灯变为绿色）
3. 设置目标日期和时间
4. 拾取或手动输入点击坐标
5. 设置点击次数和间隔
6. 点击「启动定时点击」
7. 程序将在目标时刻自动执行点击

## 构建

```bash
flutter build windows --release
```

可执行文件生成在 `build\windows\x64\runner\Release\autoclick.exe`。

## 依赖

- Flutter SDK ^3.12
- [ffi](https://pub.dev/packages/ffi) — Windows API 调用

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
