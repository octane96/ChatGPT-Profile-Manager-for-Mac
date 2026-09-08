# Security Policy / セキュリティポリシー

## Supported versions / 対応バージョン

Security fixes are developed on `master` and included in the next tagged
release when applicable. Use the newest release when possible.

セキュリティ修正は`master`で行い、必要に応じて次のタグ付きリリースへ含めます。
可能な限り最新リリースを使用してください。

| Version / バージョン | Supported / 対応 |
| --- | --- |
| Latest tagged release / 最新タグ付きリリース | Yes / 対応 |
| Older releases / 旧リリース | Best effort / 原則対象外 |
| `master` / 開発版 | Best effort / 開発中 |

## Reporting a vulnerability / 脆弱性の報告

Please do not open a public issue or Pull Request for a vulnerability that
could expose credentials, tokens, cookies, private profile data, sessions,
chats, projects, or cross-profile state.

公開IssueやPull Requestには、認証情報、トークン、Cookie、非公開プロファイルデータ、
セッション、チャット、プロジェクト、プロファイル間の状態が漏れる脆弱性を投稿しないでください。

Use [GitHub Private Vulnerability Reporting](https://github.com/octane96/ChatGPT-Profile-Manager-for-Mac/security/advisories/new).
If private reporting is unavailable, contact the maintainer through the
GitHub profile and state that the message contains a security report.

[GitHub Private Vulnerability Reporting](https://github.com/octane96/ChatGPT-Profile-Manager-for-Mac/security/advisories/new)を使用してください。
非公開報告が利用できない場合は、GitHubプロフィールからメンテナーへ連絡し、
セキュリティ報告であることを明記してください。

Include only sanitized information:

- affected version and macOS version;
- a concise description of the impact;
- reproducible steps using disposable test profiles;
- relevant, redacted logs or screenshots;
- a suggested mitigation, if known.

次のような、機密情報を含まない内容だけを送ってください。

- 影響を受けるバージョンとmacOSのバージョン
- 影響の概要
- 使い捨てのテストプロファイルで再現できる手順
- 関連するログやスクリーンショット（機密情報を削除したもの）
- 分かる場合は緩和策

Never include real `auth.json` contents, access or refresh tokens, OAuth codes,
cookies, connector credentials, private logs, account identifiers, or an
entire profile directory. Redact absolute paths when they reveal usernames or
private locations.

実際の`auth.json`の内容、アクセストークンやリフレッシュトークン、OAuthコード、
Cookie、コネクターの認証情報、非公開ログ、アカウント識別子、プロファイルディレクトリ全体を
含めないでください。ユーザー名や非公開の場所が分かる絶対パスも伏せてください。

## Security boundaries / セキュリティ境界

ChatGPT Profile Manager selects separate local paths for `CODEX_HOME` and the
ChatGPT Electron user-data directory. It does not create a new OpenAI account,
move server-side data, or provide an operating-system security boundary.

ChatGPT Profile Managerは`CODEX_HOME`とChatGPT Electronユーザーデータのローカル保存先を
分けます。新しいOpenAIアカウントを作成したり、サーバー側のデータを移動したり、OSレベルの
セキュリティ境界を提供したりするものではありません。

Profiles still run as the same macOS user and can share filesystem permissions,
process visibility, keychain access, network configuration, SSH keys, and
credentials used by tools. A malicious process running as the same user may be
able to read another profile's files.

プロファイルは同じmacOSユーザーとして動作するため、ファイル権限、プロセスの可視性、キーチェーン、
ネットワーク設定、SSHキー、ツールが使用する認証情報を共有します。同じユーザーで動作する悪意ある
プロセスから、別プロファイルのファイルを読み取られる可能性があります。

Configuration sharing and copying intentionally exclude authentication data,
sessions, chats, projects, cookies, and SQLite indexes. The allowlist and
sensitive-value checks are safeguards, not proof that arbitrary configuration
text is non-secret. Review files before sharing them across trust boundaries.

設定共有と設定コピーでは、認証情報、セッション、チャット、プロジェクト、Cookie、SQLite索引を
意図的に対象外としています。許可リストと機密値チェックは安全策であり、任意の設定テキストに秘密が
含まれないことを保証するものではありません。信頼境界をまたいで共有する前に内容を確認してください。

For strict or regulated separation, use separate macOS users or separately
managed devices.

厳格な分離や規制対象の運用が必要な場合は、macOSユーザーまたは管理対象デバイスを分けてください。
