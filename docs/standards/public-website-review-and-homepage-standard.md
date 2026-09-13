# 公开主页与应用商店审核规范

本规范定义 XWork Technologies 面向 Google Play 和 Apple App Review 的公开网站要求，同时约束主页设计、法律页面、域名路由和发布验收。网站必须是审核员可在不登录、不安装应用和不通过人工授权的情况下访问的公开材料，而不是控制台登录入口。

## 1. 审核目标

每个发布环境都必须提供稳定的品牌主页，并在同一品牌域名下直接提供以下页面：

| 路径 | 用途 | 审核要求 |
| --- | --- | --- |
| `/` | 公司与产品主页 | `200`，HTTPS，无跨品牌跳转，包含公司名称、产品用途和支持入口 |
| `/about` | 公司与产品说明 | `200`，说明法律主体和产品定位 |
| `/privacy` | 隐私政策 | `200`，公开可读，描述数据收集、使用、共享、保留和删除方式 |
| `/terms` | 使用条款 | `200`，公开可读，包含服务范围、账户责任和联系渠道 |
| `/contact` | 联系方式 | `200`，提供可工作的组织邮箱或其他稳定联系渠道 |
| `/support` | 用户支持 | `200`，提供支持入口、联系信息和问题反馈方式 |
| `/robots.txt` | 抓取规则 | `200`，不得阻止 Googlebot 或 Apple 审核访问公开页面 |
| `/sitemap.xml` | 页面索引 | `200`，只列出当前品牌域名下的规范 URL |

所有公开审核页面必须满足：

- 使用有效 HTTPS 证书，普通浏览器和无 Cookie 的自动化客户端均可打开。
- 首次响应不得返回 `3xx`；法律页面不得跳转到 `svc.plus`、`console.svc.plus` 或其他不相干域名。
- 不需要登录、订阅、验证码、地区限制或 JavaScript 才能阅读隐私政策和联系方式。
- 页面正文、`title`、`meta description`、组织结构化数据和页脚中的公司名称保持一致。采用 `XWork Technologies LLC` 作为法律主体时，所有审核材料也必须使用同一名称；品牌名 `XWork Technologies` 可作为展示名。
- 页脚必须从主页直接链接到 Privacy、Terms、Support 和 Contact，且不能指向已废弃域名。
- 主页明确说明产品是合法的 Secure Network Tunnel、Privacy Protection 或 Network Reliability 服务，不使用误导性承诺或占位内容。

## 2. 隐私与法律内容

`/privacy` 是审核必需页面，不得只放一条外部链接。页面至少要明确说明：

1. 收集哪些账户、设备、诊断和使用数据，以及每类数据的来源；
2. 每类数据用于什么目的，哪些数据是提供服务所必需的；
3. 是否与分析、托管、支付或其他第三方共享数据，以及第三方需要遵守的保护要求；
4. 数据保存期限、删除流程、撤回同意和用户行使权利的方式；
5. 组织名称、联系地址或邮箱，以及隐私问题的处理渠道。

页面必须标注最近更新时间，并在移动端可读。收集声明必须与应用内权限、SDK、App Store Connect 隐私信息和 Play Console 数据安全表保持一致。

Apple 要求 App Store Connect 中填写隐私政策 URL，并在应用内提供易于找到的入口；Apple 也要求 Support URL 提供最新联系信息。Google Play 组织账号需要验证组织网站所有权，因此网站组织名称、域名和 Play Console / Payments Profile 信息必须相互对应。官方依据见 [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)、[Apple App Review 常见问题](https://developer.apple.com/app-store/review/)、[Google Android Developer 网站验证](https://support.google.com/android-developer-console/answer/16641416) 和 [Google Play 开发者账号信息要求](https://support.google.com/googleplay/android-developer/answer/13628312)。

## 3. 主页设计标准

主页在首屏或首屏附近应让审核员确认：

- `XWork Technologies` 品牌名和一致的法律主体名称；
- 产品是什么、解决什么用户问题，以及适用的平台；
- Privacy、Terms、Support、Contact 的可见入口；
- 组织邮箱或支持渠道；
- 适用的安全、隐私和系统网络能力说明。

主页设计必须兼容移动端和桌面端，并满足这些可访问性约束：

- 语义化标题层级，页面只有一个主要 `h1`；
- 正文和链接具有清晰对比度，键盘可以聚焦和激活所有导航项；
- 不依赖悬停、动画或单一颜色传达信息；
- `lang`、页面标题、规范链接和社交预览元数据完整；
- 关键文本不是图片内文字，窄屏下不发生横向溢出；
- 法律页面使用稳定的静态或 SSR 内容，加载失败时仍能看到组织名称和联系信息。

主页可以链接到控制台完成登录，但审核信息和法律页面必须留在品牌主页域名上。品牌主页不能把审核员自动送入登录页或控制台。

## 4. 环境域名契约

环境路由必须保持如下边界：

| 环境 | 品牌主页 | 控制台/运行入口 | 规则 |
| --- | --- | --- | --- |
| UAT | `https://onwalk.net` | `https://console.onwalk.net`；`console-cloudflare-uat.onwalk.net` 仅作为已声明的 UAT 入口 | 主页和法律页面必须在 `onwalk.net` 或 `console.onwalk.net` 原地返回 `200` |
| PROD | `https://xworktech.com` | `https://console.svc.plus`；`https://console-serverless-prod.svc.plus` | 主页固定为 `xworktech.com`；不得新增或依赖 `console.xworktech.com`、`console-serverless-prod.xworktech.com` |

Frontend Router 的网站路由必须按 Host 识别品牌域名：主页和公开审核页面在品牌域名上原地渲染；登录、账户和控制台功能才按既定规则进入 `svc.plus` 控制面。新增或删除域名时必须同步更新 GitOps 声明、Cloudflare Custom Domain、DNS、canonical、robots 和 sitemap。

## 5. 发布前硬门槛

UAT 通过后才允许准备 PROD。以下任一项失败，流水线必须停止在当前环境，不得启动 PROD：

```bash
PUBLIC_HOSTS=(console.onwalk.net) # UAT；PROD 验证时改为 xworktech.com
for host in "${PUBLIC_HOSTS[@]}"; do
  for path in / /about /privacy /terms /contact /support /robots.txt /sitemap.xml; do
    curl --fail --silent --show-error --max-time 15 \
      --dump-header - --output /dev/null \
      --write-out "$host$path %{http_code} %{redirect_url}\n" \
      "https://$host$path"
  done
done
```

验收记录至少包含：

1. 每个 URL 的最终状态为 `200`，且没有 `Location` 头；
2. `Content-Type` 对 HTML 页面为 `text/html`，robots 和 sitemap 为对应文本/XML 类型；
3. HTML 的 canonical 指向当前品牌域名，不能指向旧的 `svc.plus` 页面；
4. robots 允许公开审核页面抓取，sitemap 只列当前品牌域名的有效 URL；
5. 使用无 Cookie、无登录状态的浏览器再检查一次主页、Privacy 和 Support；
6. 将 UAT workflow 运行链接、路由版本、Cloudflare Custom Domain 状态和探针结果保存到发布证据中。

生产环境的验证必须额外检查 `xworktech.com`，不能用 UAT 的 `console.onwalk.net` 结果替代。当前审核快照（2026-09-13）：UAT 的 `console.onwalk.net` 主页、法律和支持路径返回 `200`，但 `sitemap.xml` 仍返回 `404`；PROD 的 `xworktech.com` 法律路径仍会跳转到 `svc.plus`，且 `sitemap.xml` 也返回 `404`。因此两个环境都未完成本规范，PROD 保持冻结，直到 Frontend Router 提供品牌域名 sitemap、生产版本发布并通过本节验收。

## 6. 变更检查清单

- [ ] Homepage、About、Privacy、Terms、Contact、Support 在每个目标品牌域名上直接返回 `200`。
- [ ] 没有指向 `svc.plus` 的法律页跳转、旧 Custom Domain 或失效 DNS 记录。
- [ ] 组织法律名称、邮箱、地址与 Google Payments Profile、D-U-N-S、Play Console 和 App Store Connect 一致。
- [ ] Privacy 内容与应用权限、SDK、数据安全表和应用内入口一致。
- [ ] 首页页脚和应用内设置页都能打开 Privacy 和 Support。
- [ ] robots、sitemap、canonical、TLS 和移动端布局已验证。
- [ ] UAT 运行成功并保存证据；只有全部检查通过后才创建或触发 PROD 发布。
