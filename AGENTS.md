# ChatGPT Profile Manager 作業ルール

このリポジトリは、ChatGPT Profile Manager for MacのSwift macOSアプリ本体、テスト、リリース成果物を管理します。

## 関連リポジトリ

- `homebrew-tap`: Homebrew Caskの定義を管理する。アプリ本体やProfileデータは持たない。
- このリポジトリ: Swift/AppKitアプリ、テスト、アイコン、パッケージスクリプト、GitHub Releaseを管理する。

## 作業開始時

1. リポジトリのルート、現在のブランチ、作業ツリーの差分を確認する。
2. 既存の実装、テスト、README、設定を確認してから変更する。
3. Profileの認証情報、セッション、チャット、プロジェクトなどの実データを読み書き・記録しない。

## 変更の責務

- UI、Profile管理、起動・終了、診断、設定共有・コピー、ランチャー生成はこのリポジトリで変更する。
- Swiftソース、テスト、`Info.plist`、アイコン、パッケージスクリプト、アプリのバージョンを管理する。
- GitHub Releaseのタグと配布ZIPはこのリポジトリを配布元とする。
- Homebrew Caskの`version`、URL、SHA256、インストール条件は`homebrew-tap`で変更する。
- `homebrew-tap`へアプリBundle、ソースコード、ビルドキャッシュ、Profile保存先をコピーしない。

## Profile分離の前提

- Profileごとの`CODEX_HOME`、ChatGPTのElectron user-data、認証状態、セッション、チャット、プロジェクトの分離を維持する。
- stock/default Profileの削除不可や既定保存先など、既存のProfile種別ごとの制約を維持する。
- 保存構造や認証方式を変更する場合は、既存データへの影響と移行方法を明示する。

## Git操作と完了報告

- リポジトリをまたぐ変更は、リポジトリごとに差分、テスト、コミットを分けて確認する。
- 明示的な依頼がない限り、コミット、プッシュ、Pull Request作成を行わない。
- Conventional Commitsを使用し、変更範囲を簡潔に記載する。
- 完了時は、変更ファイル、実行したテスト、未実行の確認事項を報告する。
