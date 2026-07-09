#!/usr/bin/env bash
#
# sync_main_to_feature_helper.sh
# ==============================
# sync_main_to_feature.sh を「少ない引数」で呼び出すためのラッパ（ヘルパーシェル）です。
# よく使うオプションの既定値をこのファイル（または同名 .conf）に集約し、
# 実行時に外から指定するのは原則「作業ディレクトリ」だけで済むようにします。
#
# 使い方:
#   ./sync_main_to_feature_helper.sh <repo_dir> [オプション] [-- 元スクリプトへの追加オプション...]
#
# 設計上の重要ポイント（source / スイッチロール制御まわり）:
#   1) 本ヘルパーは元スクリプトを source せず「子プロセスとして実行」します。
#        - 元スクリプトの set -Eeuo pipefail / exit がヘルパーや呼び出し元シェルを
#          巻き込んで終了させないため。
#        - 元スクリプトは BASH_SOURCE 基準で自ディレクトリの common.sh を source する
#          ため、子プロセス実行ならヘルパーの配置ディレクトリ・cwd に関係なく解決できる。
#   2) スイッチロール用シェルの source は「元スクリプトのプロセス内」で行われます
#      （--auto-switch-role 時の do_switch_role）。source で反映された認証情報
#      （環境変数）はそのプロセスと子プロセス(git)へ継承されるため、ヘルパーを
#      別ディレクトリに置いてもスイッチロール制御は正常に機能します。
#   3) ただし source は「渡されたパスをそのまま開く」ため、相対パスのままだと
#      起動場所によって壊れます。本ヘルパーは repo_dir / スイッチロール用シェル /
#      ブランチ選択ディレクトリを、元スクリプトへ渡す前にすべて絶対パスへ正規化します。
#   4) 呼び出し元シェルで事前に手動スイッチロール（source <シェル>）済みの場合、
#      その認証情報(環境変数)は本ヘルパー→元スクリプトへそのまま継承されます
#      （従来の手動運用も併用可能）。
#
# 既定値のカスタマイズ:
#   - 下記「設定（自由に編集可）」の変数を書き換える、または
#   - 同ディレクトリに sync_main_to_feature_helper.conf を置いて上書きする
#     （.conf は本ヘルパー起動時に source されます。例: 同名 .conf.example 参照）。
#   - EXTRA_DEFAULT_ARGS 配列に元スクリプトのオプションを自由に追加できます。
#
# 終了コード（元スクリプトの終了コードをそのまま返します）:
#   0  成功（取り込み完了、または既に最新）
#   1  エラー
#   2  --dry-run で取り込むべき差分あり
#   3  コンフリクトが発生し、手動解決が必要
#
set -Eeuo pipefail

HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# 0. ヘルパー用の最小ログ関数
#    （common.sh には依存しない。元スクリプトの場所検証前でも使えるように自前定義）
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  H_RESET="$(printf '\033[0m')"; H_RED="$(printf '\033[31m')"
  H_YELLOW="$(printf '\033[33m')"; H_BLUE="$(printf '\033[34m')"
else
  H_RESET=""; H_RED=""; H_YELLOW=""; H_BLUE=""
fi
h_info()  { printf '%s[HELPER]%s %s\n' "$H_BLUE"   "$H_RESET" "$*" >&2; }
h_warn()  { printf '%s[HELPER]%s %s\n' "$H_YELLOW" "$H_RESET" "$*" >&2; }
h_error() { printf '%s[HELPER]%s %s\n' "$H_RED"    "$H_RESET" "$*" >&2; }
h_die()   { h_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# 1. 設定（自由に編集可）
#    ここを書き換える、もしくは同名 .conf で上書きして「毎回の指定」を減らす。
# ---------------------------------------------------------------------------
# 元スクリプトのパス。
#   - 環境変数 SYNC_MAIN_SCRIPT で上書き可。
#   - 既定はヘルパー配置ディレクトリ(helpers/)の 1 つ上の sync_main_to_feature.sh。
#     ヘルパーを別リポジトリ等へ移す場合は .conf でフルパスを指定する。
TARGET_SCRIPT="${SYNC_MAIN_SCRIPT:-${HELPER_DIR}/../sync_main_to_feature.sh}"

DEFAULT_MAIN_BRANCH="main"      # --main の既定
DEFAULT_REMOTE="origin"         # --remote の既定
DEFAULT_USE_REBASE="false"      # true なら --rebase を常に付与
DEFAULT_AUTOSTASH="true"        # true なら --autostash を常に付与
DEFAULT_ASSUME_YES="false"      # true なら -y を常に付与（CI 等向け）

# スイッチロール用シェル（別チーム提供）の既定パス。
#   環境変数 SWITCH_ROLE_SCRIPT でも指定可。空なら付与しない。
DEFAULT_SWITCH_ROLE_SCRIPT="${SWITCH_ROLE_SCRIPT:-}"
# auto: スイッチロール用シェルのパスが確定していれば --auto-switch-role を付与
# true / false: 常に付与する / しない
DEFAULT_AUTO_SWITCH_ROLE="auto"

# 元スクリプトへ常に渡す追加オプション（自由に追加してよい）
#   例: EXTRA_DEFAULT_ARGS+=("--debug")
#   例: EXTRA_DEFAULT_ARGS+=("--no-update-main")
EXTRA_DEFAULT_ARGS=()

# ---------------------------------------------------------------------------
# 2. 設定ファイル（任意）による上書き
#    ヘルパーと同じディレクトリの <ヘルパー名>.conf を source する。
#    ※ ここも「絶対パス(HELPER_DIR 基準)」で解決するため、どこから起動しても安全。
# ---------------------------------------------------------------------------
CONF_FILE="${HELPER_DIR}/${HELPER_NAME%.sh}.conf"
if [[ -f "${CONF_FILE}" ]]; then
  h_info "設定ファイルを読み込みます: ${CONF_FILE}"
  # shellcheck disable=SC1090
  source "${CONF_FILE}" || h_die "設定ファイルの読み込みに失敗しました: ${CONF_FILE}"
fi

# ---------------------------------------------------------------------------
# 3. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${HELPER_NAME} <repo_dir> [オプション] [-- 元スクリプトへの追加オプション...]

説明:
  sync_main_to_feature.sh を少ない引数で呼び出すヘルパーです。
  よく使う既定値（下記）を自動付与するため、通常は <repo_dir> の指定だけで実行できます。

必須（外から必ず指定するパラメータ）:
  <repo_dir>              feature ブランチの作業ディレクトリ
                          （元スクリプトの --repo-dir に絶対パス化して渡します）

オプション:
  -b, --feature <name>    取り込み先ブランチを直接指定（--feature 相当）
  -d, --feature-from-dir <path>
                          指定ディレクトリ配下の git リポジトリから取り込み先
                          ブランチを対話選択（--feature-from-dir 相当）
  -s, --switch-role-script <path>
                          スイッチロール用シェルのパス（絶対パス化して渡します）
  -n, --dry-run           差分・コンフリクト見込みの確認のみ（--dry-run 相当）
  -r, --rebase            rebase で取り込む（--rebase 相当）
  -y, --yes               対話確認をスキップ（-y 相当）
  -h, --help              このヘルプを表示
  --                      以降の引数はそのまま元スクリプトへ渡します
                          （元スクリプトの全オプションを自由に追加指定できます）

現在の既定値（このヘルパー、または ${HELPER_NAME%.sh}.conf で変更できます）:
  元スクリプト          : ${TARGET_SCRIPT}
  --main                : ${DEFAULT_MAIN_BRANCH}
  --remote              : ${DEFAULT_REMOTE}
  --rebase              : ${DEFAULT_USE_REBASE}
  --autostash           : ${DEFAULT_AUTOSTASH}
  -y (--yes)            : ${DEFAULT_ASSUME_YES}
  スイッチロール用シェル: ${DEFAULT_SWITCH_ROLE_SCRIPT:-（未設定）}
  --auto-switch-role    : ${DEFAULT_AUTO_SWITCH_ROLE}
  追加オプション        : ${EXTRA_DEFAULT_ARGS[*]:-（なし）}

例:
  # 通常はこれだけ（既定値で main を feature に取り込む）
  ./${HELPER_NAME} ~/work/feature_login

  # まず差分確認だけ
  ./${HELPER_NAME} ~/work/feature_login -n

  # ~/work 配下のリポジトリからブランチを対話選択して取り込み
  ./${HELPER_NAME} ~/work/feature_login -d ~/work

  # 元スクリプトのオプションを追加で渡す
  ./${HELPER_NAME} ~/work/feature_login -- --no-update-main --debug
USAGE
}

# ---------------------------------------------------------------------------
# 4. パス正規化ヘルパ（相対パス → 絶対パス）
#    source やチェックが起動場所(cwd)に依存しないようにするための要。
# ---------------------------------------------------------------------------
to_abs_path() {
  local p="${1:?to_abs_path: パスが必要です}"
  if [[ -d "${p}" ]]; then
    (cd "${p}" && pwd)
  else
    local d
    d="$(cd "$(dirname "${p}")" 2>/dev/null && pwd)" \
      || h_die "パスの親ディレクトリが存在しません: ${p}"
    printf '%s/%s\n' "${d}" "$(basename "${p}")"
  fi
}

# ---------------------------------------------------------------------------
# 5. 引数パース
# ---------------------------------------------------------------------------
REPO_DIR_ARG=""
OPT_FEATURE=""
OPT_FEATURE_FROM_DIR=""
OPT_SWITCH_ROLE_SCRIPT=""
OPT_DRY_RUN="false"
OPT_REBASE="${DEFAULT_USE_REBASE}"
OPT_YES="${DEFAULT_ASSUME_YES}"
PASSTHROUGH_ARGS=()

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -b|--feature)             OPT_FEATURE="${2:-}"; shift 2 ;;
      -d|--feature-from-dir)    OPT_FEATURE_FROM_DIR="${2:-}"; shift 2 ;;
      -s|--switch-role-script)  OPT_SWITCH_ROLE_SCRIPT="${2:-}"; shift 2 ;;
      -n|--dry-run)             OPT_DRY_RUN="true"; shift 1 ;;
      -r|--rebase)              OPT_REBASE="true"; shift 1 ;;
      -y|--yes)                 OPT_YES="true"; shift 1 ;;
      -h|--help)                usage; exit 0 ;;
      --)                       shift; PASSTHROUGH_ARGS=("$@"); break ;;
      -*)                       usage; h_die "不明なオプションです: ${1}（元スクリプトのオプションは -- の後に指定してください）" ;;
      *)
        if [[ -z "${REPO_DIR_ARG}" ]]; then
          REPO_DIR_ARG="${1}"; shift 1
        else
          usage; h_die "位置引数が多すぎます: ${1}（repo_dir は 1 つだけ指定してください）"
        fi
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 6. 引数チェック（外から必ず指定が必要なパラメータの検証）
# ---------------------------------------------------------------------------
validate_args() {
  # repo_dir: 必須
  if [[ -z "${REPO_DIR_ARG}" ]]; then
    usage
    h_die "作業ディレクトリ <repo_dir> は必須です。"
  fi
  [[ -d "${REPO_DIR_ARG}" ]] \
    || h_die "作業ディレクトリが存在しません: ${REPO_DIR_ARG}"

  # ブランチ指定の排他チェック（元スクリプトでも検証されるが、早期に分かりやすく落とす）
  if [[ -n "${OPT_FEATURE}" && -n "${OPT_FEATURE_FROM_DIR}" ]]; then
    usage
    h_die "-b/--feature と -d/--feature-from-dir は同時に指定できません。"
  fi
  if [[ -n "${OPT_FEATURE_FROM_DIR}" && ! -d "${OPT_FEATURE_FROM_DIR}" ]]; then
    h_die "-d/--feature-from-dir のディレクトリが存在しません: ${OPT_FEATURE_FROM_DIR}"
  fi

  # スイッチロール用シェル: 指定（引数 > 既定値）があるなら存在確認
  if [[ -n "${OPT_SWITCH_ROLE_SCRIPT}" && ! -f "${OPT_SWITCH_ROLE_SCRIPT}" ]]; then
    h_die "スイッチロール用シェルが見つかりません: ${OPT_SWITCH_ROLE_SCRIPT}"
  fi
}

# ---------------------------------------------------------------------------
# 7. 元スクリプトの検証
#    - 子プロセス実行するため実行対象そのものと、元スクリプトが source する
#      common.sh（元スクリプトと同じディレクトリ）が揃っているかを事前確認する。
# ---------------------------------------------------------------------------
validate_target() {
  [[ -f "${TARGET_SCRIPT}" ]] \
    || h_die "元スクリプトが見つかりません: ${TARGET_SCRIPT}（環境変数 SYNC_MAIN_SCRIPT か ${CONF_FILE##*/} で正しいパスを指定してください）"
  TARGET_SCRIPT="$(to_abs_path "${TARGET_SCRIPT}")"

  local target_dir
  target_dir="$(dirname "${TARGET_SCRIPT}")"
  [[ -f "${target_dir}/common.sh" ]] \
    || h_die "元スクリプトが source する common.sh が見つかりません: ${target_dir}/common.sh"
}

# ---------------------------------------------------------------------------
# 8. 元スクリプトへ渡す引数の組み立て
# ---------------------------------------------------------------------------
build_and_run() {
  local -a args=()

  # 必須・既定オプション（パスはすべて絶対パス化して渡す）
  args+=(--repo-dir "$(to_abs_path "${REPO_DIR_ARG}")")
  args+=(--main "${DEFAULT_MAIN_BRANCH}")
  args+=(--remote "${DEFAULT_REMOTE}")
  [[ "${DEFAULT_AUTOSTASH}" == "true" ]] && args+=(--autostash)
  [[ "${OPT_REBASE}" == "true" ]]        && args+=(--rebase)
  [[ "${OPT_DRY_RUN}" == "true" ]]       && args+=(--dry-run)
  [[ "${OPT_YES}" == "true" ]]           && args+=(-y)

  # ブランチ指定（直接指定 / ディレクトリからの対話選択）
  [[ -n "${OPT_FEATURE}" ]] && args+=(--feature "${OPT_FEATURE}")
  if [[ -n "${OPT_FEATURE_FROM_DIR}" ]]; then
    args+=(--feature-from-dir "$(to_abs_path "${OPT_FEATURE_FROM_DIR}")")
  fi

  # スイッチロール制御:
  #   スイッチロール用シェルは元スクリプトのプロセス内で source されるため、
  #   別ディレクトリのヘルパー経由でも「絶対パスで渡しさえすれば」正常に動作する。
  local switch_script="${OPT_SWITCH_ROLE_SCRIPT:-${DEFAULT_SWITCH_ROLE_SCRIPT}}"
  if [[ -n "${switch_script}" ]]; then
    [[ -f "${switch_script}" ]] \
      || h_die "スイッチロール用シェルが見つかりません: ${switch_script}"
    switch_script="$(to_abs_path "${switch_script}")"
    args+=(--switch-role-script "${switch_script}")
  fi
  case "${DEFAULT_AUTO_SWITCH_ROLE}" in
    true)  args+=(--auto-switch-role) ;;
    false) : ;;
    auto)  [[ -n "${switch_script}" ]] && args+=(--auto-switch-role) ;;
    *)     h_die "DEFAULT_AUTO_SWITCH_ROLE は auto/true/false のいずれかで指定してください: '${DEFAULT_AUTO_SWITCH_ROLE}'" ;;
  esac

  # 設定ファイル等で自由に追加された既定オプション
  args+=(${EXTRA_DEFAULT_ARGS[@]+"${EXTRA_DEFAULT_ARGS[@]}"})
  # -- 以降にユーザが指定した追加オプション（最後に置き、既定より優先されうる）
  args+=(${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"})

  h_info "実行します: bash ${TARGET_SCRIPT} ${args[*]}"

  # source ではなく子プロセスとして実行する（ヘッダコメントの設計ポイント参照）。
  # 元スクリプトの終了コード(0/1/2/3)をそのまま呼び出し元へ返す。
  local rc=0
  bash "${TARGET_SCRIPT}" "${args[@]}" || rc=$?

  case "${rc}" in
    0) h_info "完了しました（取り込み成功、または既に最新）。" ;;
    2) h_warn "dry-run: 取り込むべき差分があります。実行する場合は -n を外して再実行してください。" ;;
    3) h_warn "コンフリクトが発生しています。表示されたガイドに従って解決してください。" ;;
    *) h_error "元スクリプトがエラー終了しました (exit=${rc})。" ;;
  esac
  exit "${rc}"
}

# ---------------------------------------------------------------------------
# 9. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_args
  validate_target
  build_and_run
}

main "$@"
