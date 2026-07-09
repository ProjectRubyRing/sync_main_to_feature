#!/usr/bin/env bash
#
# common.sh - 複数のスクリプトで共有するユーティリティ関数群
#
# 使い方:
#   このファイルを source して各関数を利用する。
#     source "$(dirname "$0")/common.sh"
#
#   DRY_RUN=true を設定すると run() は実コマンドを実行せず表示のみ行う。
#
# 注意: このファイル自体は単体実行を想定していない（source 専用）。

# 既に読み込み済みなら何もしない（多重 source 対策）
#   注意: マーカー変数が環境に漏れていても、関数が未定義の新しいシェルでは
#   必ず定義し直すよう「変数あり かつ 関数定義済み」を読み込み済みの条件とする。
if [[ -n "${COMMON_SH_LOADED:-}" ]] && declare -F require_command >/dev/null 2>&1; then
  return 0 2>/dev/null || exit 0
fi
COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# 色定義（端末が対応している場合のみ色を付ける）
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET="$(printf '\033[0m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
else
  C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

# ---------------------------------------------------------------------------
# ログ関数
# ---------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s  %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_success() { printf '%s[OK]%s    %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()    { printf '%s[WARN]%s  %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

# エラーメッセージを出して終了する
# usage: die "メッセージ" [終了コード]
die() {
  local msg="$1"
  local code="${2:-1}"
  log_error "$msg"
  exit "$code"
}

# ---------------------------------------------------------------------------
# コマンド実行ヘルパー
#   DRY_RUN=true のときは実行内容を表示するだけで実行しない。
#   それ以外のときは表示してから実行する。
#
# usage: run git push origin --delete feature/foo
# ---------------------------------------------------------------------------
run() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '%s[DRY-RUN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
    return 0
  fi
  printf '%s[RUN]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
  "$@"
}

# ---------------------------------------------------------------------------
# 確認プロンプト
#   ASSUME_YES=true（--yes 相当）のときは確認せず yes とみなす。
#   DRY_RUN=true のときも確認をスキップする（破壊的操作は実行されないため）。
#
# usage: if confirm "本当に削除しますか?"; then ... ; fi
# 戻り値: yes -> 0, no -> 1
# ---------------------------------------------------------------------------
confirm() {
  local prompt="${1:-続行しますか?}"

  if [[ "${ASSUME_YES:-false}" == "true" ]]; then
    return 0
  fi
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    log_info "(dry-run のため確認をスキップ)"
    return 0
  fi

  local reply
  read -r -p "$prompt [y/N]: " reply
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 必須コマンドの存在確認
# usage: require_command git
# ---------------------------------------------------------------------------
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "コマンドが見つかりません: $cmd"
}

# ---------------------------------------------------------------------------
# 指定ディレクトリ配下から git リポジトリ(.git が存在するディレクトリ)を探索し、
# 各リポジトリのチェックアウト中ブランチを番号付きの選択肢として表示する。
# ユーザが選択したブランチ名を標準出力へ返す
# (呼び出し側でブランチ名を直接指定する引数の代わりに使う)。
#
# usage: select_branch_from_dir <base_dir> [max_depth(既定: 3)]
#   例: branch="$(select_branch_from_dir ~/work)"
#
#   - .git はディレクトリだけでなくファイル(worktree / submodule)も対象とする。
#   - detached HEAD などブランチ名を特定できないリポジトリは警告してスキップする。
#   - メニュー・プロンプトはすべて stderr へ出力する(stdout は選択結果専用。
#     このファイルの log_info は stdout へ出力するため、本関数内では使わない)。
#   - 入力は /dev/tty から読む(コマンド置換 `$(...)` 内でも対話できるようにするため)。
#     対話端末が無い場合はエラー終了する。
# ---------------------------------------------------------------------------
select_branch_from_dir() {
  local base="${1:?select_branch_from_dir: ディレクトリを指定してください}"
  local max_depth="${2:-3}"

  [[ -d "${base}" ]] || die "ブランチ選択用のディレクトリが見つかりません: ${base}"
  require_command git
  require_command find

  # --- git リポジトリの探索 -------------------------------------------------
  #   .git を見つけたら -prune でその配下(リポジトリ内部)へは降りない。
  local -a repo_dirs=() repo_branches=()
  local gitpath repo_dir branch
  while IFS= read -r gitpath; do
    repo_dir="$(dirname "${gitpath}")"
    # チェックアウト中のブランチ名(detached HEAD の場合は取得できない)
    if branch="$(git -C "${repo_dir}" symbolic-ref --short -q HEAD 2>/dev/null)" \
        && [[ -n "${branch}" ]]; then
      repo_dirs+=("${repo_dir}")
      repo_branches+=("${branch}")
    else
      log_warn "ブランチを特定できないためスキップします(detached HEAD 等): ${repo_dir}"
    fi
  done < <(find "${base}" -maxdepth "${max_depth}" -name .git -prune \
             \( -type d -o -type f \) -print 2>/dev/null | sort)

  [[ "${#repo_dirs[@]}" -ge 1 ]] \
    || die "指定ディレクトリ配下に git リポジトリ(.git)が見つかりませんでした: ${base}"

  # --- 選択肢の表示(stderr) -------------------------------------------------
  printf '%s[INFO]%s  ブランチを選択してください(%s 配下の git リポジトリから検出):\n' \
    "$C_BLUE" "$C_RESET" "${base}" >&2
  local i
  for i in "${!repo_dirs[@]}"; do
    printf '  %2d) %s  (ブランチ: %s)\n' \
      "$((i + 1))" "${repo_dirs[$i]}" "${repo_branches[$i]}" >&2
  done

  # --- 対話入力(/dev/tty) ---------------------------------------------------
  [[ -r /dev/tty ]] \
    || die "対話端末が無いためブランチを選択できません。ブランチ名を引数で直接指定してください。"

  local ans=""
  while :; do
    printf '番号を入力してください [1-%d] (q で中止): ' "${#repo_dirs[@]}" >&2
    read -r ans </dev/tty 2>/dev/null \
      || die "入力を読み取れませんでした。対話端末が無い場合はブランチ名を引数で直接指定してください。"
    case "${ans}" in
      q|Q)
        die "ブランチ選択を中止しました。" ;;
      ''|*[!0-9]*)
        log_warn "数値を入力してください: ${ans}" ;;
      *)
        if [[ "${ans}" -ge 1 && "${ans}" -le "${#repo_dirs[@]}" ]]; then
          branch="${repo_branches[$((ans - 1))]}"
          printf '%s[INFO]%s  選択されたブランチ: %s (%s)\n' \
            "$C_BLUE" "$C_RESET" "${branch}" "${repo_dirs[$((ans - 1))]}" >&2
          printf '%s\n' "${branch}"
          return 0
        fi
        log_warn "1〜${#repo_dirs[@]} の範囲で入力してください: ${ans}"
        ;;
    esac
  done
}
