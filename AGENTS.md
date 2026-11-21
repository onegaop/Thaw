# AGENTS.md

Notes for AI coding agents and the people driving them. Read this before changing code.

Thaw 3 (macOS 27) lives on `development`. Thaw 2 (macOS 26) lives on `legacy/thaw-2`, which takes fixes and 2.x releases only and never merges back. Open the PR against the branch for the line you changed. Where the two branches differ, this file says so.

## macOS 26 维护分支

### 同步上游

本地二开沿用 Thaw 2 的菜单栏后端。先用 `git remote -v` 核对官方源为 `https://github.com/thaw-app/Thaw.git`，用 `git ls-remote --heads --tags origin` 核对维护线与 2.x 标签。2026-11-21 核对的稳定版为 `2.1.0`，预发布版为 `2.2.0-beta.2`。本次选择 `legacy/thaw-2` 的 `51e8d6c`，包含标签之后的浮动栏着色修复。Thaw 3 的 `development` 依赖 macOS 27 的菜单栏后端。借用其单项修复时，应先检查 API 可用性、内嵌二进制最低系统及在 26 上的行为。

1. 用 `git worktree list`、`git status --short --branch` 和 `git log -5 --oneline` 核对本地二开基线。用 `git worktree add -b <新分支> <新目录> <二开提交>` 隔离操作，保留原工作树、暂存区和未跟踪文件。
2. 在新工作树运行 `git fetch --no-tags origin refs/heads/legacy/thaw-2:refs/remotes/origin/legacy/thaw-2`。对于浅仓库，如缺少共同祖先，可只加深这条维护线。检查 `git merge-base HEAD origin/legacy/thaw-2`，查看两边独有提交、工程和包锁定文件的差异。
3. 用 `git merge --no-ff --no-commit origin/legacy/thaw-2` 预合并。对两边均改过的文件分别核对相对两个父提交的差异，尤其是 `IceBar.swift`。解决冲突、验证并用 `git commit -s` 本地提交。推送、发布、替换应用及系统升级均须另行安排。

### 兼容改动

- 应用身份为 `com.tony.thaw.compat26`，URL 为 `thaw-compat26://`。配置、日志、Focus 通知与 XPC 服务使用兼容版的命名，Sparkle 更新保持关闭。运行 `python3 scripts/check-compat-isolation.py` 检查隔离配置。
- 定时、焦点变化和智能点击收起任务在等待结束时复核自动收起开关、取消状态和策略。相应测试在 `RehideStrategyTests`。
- `ThawBarContentFit` 记录理想尺寸与 AppKit 实际取整尺寸，真实内容或窗口变化时仍会重新适配。独立浮动栏底色绘在图标后方，文字和图标按实际背景亮度选择前景。分别验证 `ThawBarContentFitTests` 和 `MenuBarContainerTintTests`。历史设计及身份隔离详见 [macOS 26 回移记录](docs/MACOS26_BACKPORT.md)。

### 本地构建和测试

在隔离工作树根目录运行。可将 `packages` 指向已有的 SwiftPM 依赖缓存；为本次候选指定独立 DerivedData。验证工程原始配置，命令行不覆盖部署目标。

```sh
ddir=../Thaw-build
packages=../Thaw-packages
xcodebuild -project Thaw.xcodeproj -scheme Thaw -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$ddir" \
  -clonedSourcePackagesDirPath "$packages" -disableAutomaticPackageResolution \
  -skipPackageUpdates CODE_SIGNING_ALLOWED=NO build
app="$ddir/Build/Products/Release/Thaw.app"
plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist"
xcrun vtool -show-build "$app/Contents/MacOS/Thaw"
"$app/Contents/MacOS/Thaw" --compatibility-self-test
python3 scripts/check-compat-isolation.py
swiftlint lint --strict
```

同时核对两个内嵌 XPC 及所有内嵌框架的 Mach-O `minos`，每个架构都应可在 26 上加载。自检在 AppKit 启动前退出。可用 `build-for-testing` 检查测试能否编译。ThawTests 使用应用宿主，完整 `xcodebuild test` 应在独立的测试用户会话执行，使用测试布局和配置，避免干扰日常菜单栏。记录实际执行的套件、结果及任何既有 lint 问题。

在使用菜单栏的 Mac 上，可复现本次四套无界面回归。以下命令接续上面的变量，使用 Xcode 27.2 的 Swift Testing 和本机 arm64 Debug 构建布局，将四个原始测试目标文件链接到独立入口。测试运行器只加载应用代码库，不调用 Thaw 的启动入口。

```sh
xcodebuild -project Thaw.xcodeproj -scheme Thaw -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$ddir" \
  -clonedSourcePackagesDirPath "$packages" -disableAutomaticPackageResolution \
  -skipPackageUpdates -jobs 4 CODE_SIGNING_ALLOWED=NO build-for-testing

builddir=$(cd "$ddir" && pwd)
run="$builddir/CompatRegression"
obj="$builddir/Build/Intermediates.noindex/Thaw.build/Debug/ThawTests.build/Objects-normal/arm64"
contents="$builddir/Build/Products/Debug/Thaw.app/Contents"
frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
mkdir -p "$run"
cat > "$run/Run.swift" <<'SWIFT'
import Darwin
import Testing

@main
enum Run {
    static func main() async {
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
SWIFT
xcrun swiftc -profile-generate -parse-as-library "$run/Run.swift" \
  "$obj/MenuBarContainerTintTests.o" "$obj/ThawBarContentFitTests.o" \
  "$obj/RehideStrategyTests.o" "$obj/CompatibilityIsolationTests.o" \
  "$contents/MacOS/Thaw.debug.dylib" -F "$frameworks" -F "$contents/Frameworks" \
  -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$contents/MacOS" \
  -Xlinker -rpath -Xlinker "$contents/Frameworks" -o "$run/TestRunner"
LLVM_PROFILE_FILE="$run/regression-%p.profraw" "$run/TestRunner"
```

### 真实菜单栏验收

在 macOS 26 的独立交互会话中，只运行一个菜单栏管理器。记录候选提交、系统、显示器、缩放和已授予的权限。检查屏幕录制与辅助功能状态时保留日常用户的权限和设置。

1. 在测试配置中启用悬停显示，并为当前显示器启用 Thaw Bar。隐藏区至少放一个可辨识的测试图标。将指针移到菜单栏空白处，停留超过悬停延时，确认浮动栏在预期显示器展开。Thaw 图标、其他状态项和应用菜单均不属于这个触发区域。
2. 延时结束前移出应取消展开；从菜单栏移入浮动栏应保持打开。移出两者后检查是否按已设收起间隔关闭，再次悬停应能重新打开。记录实际显示、图标可见性和点击结果。
3. 检查独立外观下的完全不透明底色、渐变及继承菜单栏外观。确认图标清晰可点击；在可用的缩放和外接屏条件下反复展开，观察抖动、裁切和重新定位。
4. 检查手动显示/隐藏、切换收起策略、等待期间禁用自动收起，以及临时显示后再次收起。切换测试配置或显示器后，复核项目顺序及始终隐藏区。把未实测的场景逐项标出。

## Don't add responsibilities to the big types

We are breaking up a handful of types that do too much. Bug fixes are still the priority, but no change should give these types more to do. This applies on both branches, and matters most on `development`, where the breakup is happening.

| Type | What it does today |
|---|---|
| `MenuBarItemManager` | The worst one, split over many extension files that share one pool of state: item cache, moves, section order, repair, startup, persistence, clicks, failure tracking |
| `MenuBarItemImageCache` | Captures and caches item images, schedules recaptures, and also reveals hidden items to capture them |
| `MenuBarManager` | Showing and hiding sections, rehide timers, app-menu hiding, profile application, overlay state |
| `HIDEventManager` | Every input path: click, hover, scroll, drag, Clock and Notification Center taps |
| `ControlItem` | The status item, its look, its recovery and its length changes |
| `ProfileManager` | Stores profiles, switches them by display, Space or Focus, applies layout and spacing |

The rule: don't add new responsibilities to these types. A stored property and a few forwarding calls to plug in an extracted module are fine. If a bug fix has to change one of them in place, keep it small and say why in the PR.

Where new behavior goes:

1. Extend an existing focused module when the responsibility fits there.
2. Otherwise, extract the behavior together with the state it owns, behind a small interface.
3. Avoid wrappers that only forward calls. Moving a method out while its state stays behind doesn't make the big type any smaller.
4. Keep decision logic in pure functions that take values and return values, and test the module through its interface.

`AppState` is small but works as a service locator: almost everything reaches through `appState.menuBarManager`, `appState.itemManager` or `appState.settings`. Give a new type the dependencies it needs instead of adding another reach through `AppState`.

These are large but fine as they are, so don't split them for the sake of it: `MenuBarItemAXProvider` and `SettingsURIHandler` (stateless), `MenuBarOverlayPanel.swift` (several views in one file), `LayoutBarPaddingView` and `SearchIndex`.

## SonarCloud

New code needs at least 80% test coverage; that is the project's policy. The SonarCloud scan reports coverage along with duplicated code and new bugs, vulnerabilities and code smells, so keep those at zero on what you add.

CI skips the analysis for pull requests from forks and from Dependabot. A skipped Sonar check means nothing was analyzed, not that the change passed.

Don't add files to `sonar.coverage.exclusions` in `sonar-project.properties` to get under the bar. That list is for code that can only run against a live menu bar, and the PR has to say why a file belongs there.

Additional team conventions:

- Code comments are plain sentences: no headings, bold, bullet lists or tables.
- If you'd copy a block, pull it into a shared function instead.

## Lint

Lint locally, then let CI confirm. A green Xcode build is not proof that lint passed. Don't disable rules or add suppressions just to make a change pass.

On `development`:

- Run `sh scripts/lint.sh --strict`. It checks that the SwiftLint version matches `.swiftlint-version`, and CI runs the same.
- The file, function, type, complexity and nesting limits are on. Violations that were already there are kept in `.swiftlint.baseline`, so only new ones report. Don't add entries to the baseline to make room for new code.

On `legacy/thaw-2`:

- Run `swiftlint lint --strict`. CI runs the same.
- The Xcode build phase runs `swiftlint` without `--strict` and always marks itself done, so it doesn't reliably stop the build.
- When you add, delete or rename a Swift file in a linted directory, regenerate the input list with `bash scripts/generate-swiftlint-inputs.sh`. The script reads Git-tracked paths, so stage new files first. CI regenerates the list and fails if it differs from `scripts/swiftlint-inputs.xcfilelist`.

## Tests and formatting

- Tests use Swift Testing (`@Test`, `#expect`). Don't add XCTest.
- Add automated tests for new behavior and regression tests for bug fixes when practical. If a change needs checking on a live menu bar, say what the automated tests can't cover and write down the manual checks you did.
- Ask before running checks that reset permissions or preferences, change the live menu bar layout, or quit other apps. Use separate test data instead of the user's own settings.
- Run `swiftformat .` before committing. See [Development](docs/DEVELOPMENT.md) for build and test commands.

## Commits and pull requests

The shared [contribution guidelines](https://github.com/thaw-app/.github/blob/main/.github/CONTRIBUTING.md) are the source of truth. In short:

1. **Sign off every commit** with `git commit -s`. The `Signed-off-by` trailer uses the contributor's real name and an email that matches the commit author. Never make up an identity; if Git's name or email isn't set, ask. Sign-off is not cryptographic signing (`-S`).
2. **Use and complete the [PR template](.github/pull_request_template.md)**, including when you open the PR with `gh`. Keep all its sections, and leave a checklist item unchecked when you didn't do it or it doesn't apply.
3. **Title the PR as a Conventional Commit,** such as `fix(layout): preserve item order`. Put `Closes: #123` on its own line, or `Closes: N/A` when there is no issue. Bug fixes and features from outside the team need an issue first.
4. **Agree on scope first.** Discuss features, substantial refactors and sensitive changes in an issue before writing them. Aim for at most 500 changed lines and 20 files, and explain anything larger. Write down the test commands you ran, their results, and the macOS versions you tested on.
5. **Translations go through [Crowdin](https://crowdin.com/project/thaw),** not translation PRs. Changing or adding the source strings a feature needs is fine.
6. **Review AI-generated changes before you submit them.** The contributor stays responsible for understanding the code, where it came from, its license compatibility and its tests.

## Reporting your work

- Keep each PR focused. Follow the issue-linking requirements above.
- User-facing changes get a line in [CHANGELOG.md](CHANGELOG.md), written for users, not for developers.
- Report the checks you actually ran and their results. Name any check you skipped or couldn't run.