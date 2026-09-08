# Contributing / 貢献ガイド

Thank you for helping improve ChatGPT Profile Manager. This project manages
separate local runtime environments for the ChatGPT desktop app on macOS.

ChatGPT Profile Managerの改善に協力していただきありがとうございます。このプロジェクトは、
macOS上のChatGPTデスクトップアプリ用に分離されたローカル実行環境を管理します。

## Before you start / 開発環境

- macOS 14 or later
- Apple Silicon (arm64) Mac for the current release build
- Xcode Command Line Tools or Xcode with Swift 6 support

- macOS 14以降
- 現在のリリースビルドを実行する場合はApple Silicon（arm64）Mac
- Swift 6に対応したXcodeまたはXcode Command Line Tools

Clone the repository and run the same checks used by CI:

```sh
git clone https://github.com/octane96/ChatGPT-Profile-Manager-for-Mac.git
cd ChatGPT-Profile-Manager-for-Mac
swift test --disable-sandbox
swift build --disable-sandbox --configuration release
```

リポジトリをクローンし、CIと同じチェックを実行してください。SwiftPMのキャッシュ先に
書き込めない環境では、書き込み可能な一時ディレクトリを
`CLANG_MODULE_CACHE_PATH`と`SWIFTPM_MODULECACHE_OVERRIDE`に指定してください。

## Development workflow / 開発の流れ

1. Create a topic branch; do not work directly on `master` or `staging`.
2. Keep each change focused and explain the user-visible impact.
3. Add or update regression tests for observable behavior changes.
4. Run the tests and release build locally.
5. Open a Pull Request with a summary, verification commands, and any known limitations.

1. 作業用ブランチを作成し、`master`や`staging`へ直接変更を加えない。
2. 変更の目的を絞り、利用者に見える影響を説明する。
3. 動作が変わる場合は回帰テストを追加・更新する。
4. ローカルでテストとReleaseビルドを実行する。
5. 変更概要、実行した確認、既知の制約を記載してPull Requestを作成する。

The repository requires Pull Requests for `master` and `staging`. The required
`Swift tests` check must pass before merging. Force pushes and deletion of
those branches are prohibited.

このリポジトリの`master`と`staging`への変更はPull Request経由が必要です。マージ前に
`Swift tests`チェックが成功していなければなりません。これらのブランチへのForce pushと
削除は禁止されています。

## Product and security boundaries / 製品・セキュリティ上の境界

Preserve the existing profile model:

- Each isolated profile keeps its own `CODEX_HOME` and ChatGPT Electron user-data directory.
- The existing ChatGPT environment remains the stock/default environment.
- Profiles may run in parallel when their storage locations differ; the same location must not be launched twice.
- Authentication, sessions, chats, projects, cookies, and SQLite indexes must not be copied or merged by configuration-sharing or configuration-copy features.
- Profile separation is local state separation, not an account, operating-system, or server-side security boundary.

既存のプロファイルモデルを維持してください。

- 分離プロファイルごとに`CODEX_HOME`とChatGPT Electronユーザーデータを分ける。
- ChatGPTの既存環境はstock/default環境として扱う。
- 保存先が異なるプロファイルは並列起動できるが、同じ保存先は二重起動できない。
- 設定共有・設定コピーで認証情報、セッション、チャット、プロジェクト、Cookie、SQLite索引をコピー・統合しない。
- プロファイル分離はローカル状態の分離であり、アカウント、OS、サーバー側のセキュリティ境界ではない。

Do not commit or share real `auth.json`, access or refresh tokens, cookies,
private logs, chat/project data, or unredacted profile directories. See
[SECURITY.md](SECURITY.md) before handling security-sensitive behavior.

実際の`auth.json`、アクセストークンやリフレッシュトークン、Cookie、非公開ログ、
チャット・プロジェクトデータ、未加工のプロファイルディレクトリをコミット・共有しないでください。
セキュリティに関わる変更は、事前に[SECURITY.md](SECURITY.md)を確認してください。

## Pull Request checklist / Pull Requestチェックリスト

- [ ] The change is scoped and does not alter unrelated behavior.
- [ ] Tests were added or updated when behavior changed.
- [ ] `swift test --disable-sandbox` passes.
- [ ] `swift build --disable-sandbox --configuration release` passes.
- [ ] No credentials, tokens, cookies, private logs, or profile data are included.
- [ ] README or user-facing documentation is updated when needed.

- [ ] 変更範囲が明確で、無関係な動作を変更していない。
- [ ] 動作変更に対応するテストを追加・更新した。
- [ ] `swift test --disable-sandbox`が成功している。
- [ ] `swift build --disable-sandbox --configuration release`が成功している。
- [ ] 認証情報、トークン、Cookie、非公開ログ、プロファイルデータを含めていない。
- [ ] 必要に応じてREADMEや利用者向けドキュメントを更新した。

For security vulnerabilities, do not open a public Pull Request. Follow the
private reporting process in [SECURITY.md](SECURITY.md).

セキュリティ脆弱性については、公開Pull Requestを作成しないでください。
[SECURITY.md](SECURITY.md)の非公開報告手順を使用してください。
