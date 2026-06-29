#!/usr/bin/env bash
#
# sync_main_to_feature.sh
# =======================
# CodeCommit_Git_branch_local_Create の create_feature_branch.sh で作成した
# 「feature/hotfix ブランチの作業ディレクトリ」に対して、リモートの main が
# プルリクエストでマージ・最新化された後に、その最新内容を取り込むスクリプトです。
#
# 位置づけ:
#   - create_feature_branch.sh は `git clone --single-branch --branch main` で
#     main を clone し、その中で feature/hotfix ブランチを `switch -c` して作ります。
#     => リモート追跡は origin/main のみ。feature ブランチはローカル限定です。
#   - 本スクリプトは、その作業ディレクトリで「origin/main の最新を feature に取り込む」
#     ことを安全に行います。既定では merge（マージコミットを作る）です。
#   - マージでコンフリクトが発生した場合は、競合ファイルの一覧・競合マーカーの読み方・
#     解消手順（編集→add→commit / rebase --continue）・中断方法をガイドします。
#
# 「最新化を反映する」とは（既定 = merge）:
#   1. origin から最新を fetch（--prune）
#   2. （任意）ローカル main を origin/main に fast-forward 追従
#   3. 現在の feature ブランチに origin/main を merge
#   4. コンフリクトが無ければ完了。あればガイドを表示して、解決を支援
#
# clean-pull 系スクリプトとの違い:
#   - codecommit-clean-pull.sh は「ローカル変更を破棄して main に hard reset」する
#     破壊的同期です。本スクリプトは feature の作業内容を保ったまま main を「取り込む」
#     非破壊的なマージ/リベースを行います（コンフリクト時もローカル成果物は失いません）。
#
# 認証について:
#   - すでに clone 済みのリポジトリに fetch するため、origin の URL と Git 資格情報
#     ヘルパ（HTTPS+IAM / git-remote-codecommit 等）が設定済みである前提です。
#
# 依存: bash, git （grc remote の場合は aws, git-remote-codecommit）
# 共通部品: common.sh （log_info / log_success / log_warn / log_error / die / run /
#           confirm / require_command）
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. 共通部品(common.sh)の読み込み
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
  echo "[${SCRIPT_NAME}][ERROR] common.sh が見つかりません: ${SCRIPT_DIR}/common.sh" >&2
  exit 1
fi
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# common.sh には log_debug が無いため、DEBUG=true のときだけ stderr に出力する
# デバッグログヘルパをローカル定義する（色は common.sh の定義を流用）。
log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] || return 0
  printf '%s[DEBUG]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
REPO_DIR=""                 # feature 作業ディレクトリ（必須）
MAIN_BRANCH="main"          # 取り込み元（最新化された）ブランチ
FEATURE_BRANCH=""           # 取り込み先。未指定なら現在チェックアウト中のブランチ
REMOTE="origin"             # リモート名
USE_REBASE="false"          # true なら merge ではなく rebase で取り込む
UPDATE_LOCAL_MAIN="true"    # true ならローカル main を origin/main に ff 追従させる
AUTOSTASH="false"           # true なら作業ツリーの未コミット変更を一時退避してから取り込む
DRY_RUN="false"             # true なら取り込みは行わず、差分・見込みだけ表示
ASSUME_YES="false"          # true なら対話確認をスキップ
DEBUG="${DEBUG:-false}"     # true で log_debug を有効化
export DEBUG

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --repo-dir <path> [オプション]

説明:
  feature/hotfix ブランチの作業ディレクトリに、リモートの ${MAIN_BRANCH} ブランチの
  最新内容を取り込みます（既定: merge）。feature の作業成果は保持されます。
  コンフリクトが発生した場合は、競合ファイルと解消手順をガイドします。

必須:
  --repo-dir   <path>     create_feature_branch.sh で作成した作業ディレクトリの絶対パス

オプション:
  --main       <name>     取り込み元ブランチ (既定: ${MAIN_BRANCH})
  --feature    <name>     取り込み先ブランチ (既定: 現在チェックアウト中のブランチ)
  --remote     <name>     リモート名 (既定: ${REMOTE})
  --rebase                merge ではなく rebase で取り込む（履歴を一直線に保つ）
  --no-update-main        ローカル ${MAIN_BRANCH} を origin/${MAIN_BRANCH} に追従させない
  --autostash             未コミットの変更を一時退避してから取り込み、後で復元する
  --dry-run               取り込みは行わず、差分・コンフリクト見込みのみ表示する
  -y, --yes               取り込み実行前の対話確認をスキップする
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

例:
  # まず差分とコンフリクト見込みを確認（変更しない）
  ./${SCRIPT_NAME} --repo-dir ~/work/feature_login --dry-run

  # main の最新を現在の feature ブランチに merge で取り込む
  ./${SCRIPT_NAME} --repo-dir ~/work/feature_login

  # rebase で取り込む（CI 等の非対話環境では -y）
  ./${SCRIPT_NAME} --repo-dir ~/work/feature_login --rebase --yes

  # 未コミットの編集を退避してから取り込む
  ./${SCRIPT_NAME} --repo-dir ~/work/feature_login --autostash

終了コード:
  0  成功（取り込み完了、または既に最新で取り込み不要）
  1  エラー
  2  --dry-run で取り込むべき差分あり
  3  コンフリクトが発生し、手動解決が必要（リポジトリは解決待ち状態）
USAGE
}

# ---------------------------------------------------------------------------
# 3. 引数パース
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --repo-dir)        REPO_DIR="${2:-}"; shift 2 ;;
      --main)            MAIN_BRANCH="${2:-}"; shift 2 ;;
      --feature)         FEATURE_BRANCH="${2:-}"; shift 2 ;;
      --remote)          REMOTE="${2:-}"; shift 2 ;;
      --rebase)          USE_REBASE="true"; shift 1 ;;
      --no-update-main)  UPDATE_LOCAL_MAIN="false"; shift 1 ;;
      --autostash)       AUTOSTASH="true"; shift 1 ;;
      --dry-run)         DRY_RUN="true"; shift 1 ;;
      -y|--yes)          ASSUME_YES="true"; shift 1 ;;
      --debug)           DEBUG="true"; export DEBUG; shift 1 ;;
      -h|--help)         usage; exit 0 ;;
      *)                 usage; die "不明なオプションです: ${1}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4. 入力検証
# ---------------------------------------------------------------------------
validate_inputs() {
  [[ -n "${REPO_DIR}" ]]     || { usage; die "--repo-dir は必須です。"; }
  [[ -d "${REPO_DIR}" ]]     || die "指定ディレクトリが存在しません: ${REPO_DIR}"
  [[ -n "${MAIN_BRANCH}" ]]  || die "--main が空です。"
  [[ -n "${REMOTE}" ]]       || die "--remote が空です。"

  # 絶対パスに正規化
  REPO_DIR="$(cd "${REPO_DIR}" && pwd)"
  case "${REPO_DIR}" in
    "/"|"") die "危険なパスのため中止します: '${REPO_DIR}'" ;;
  esac
}

# ---------------------------------------------------------------------------
# 5. git ラッパ
#   - 常に対象ディレクトリ(-C)で実行
#   - safe.directory を都度指定し、所有者違い(dubious ownership)を回避
# ---------------------------------------------------------------------------
git_r() {
  git -C "${REPO_DIR}" -c "safe.directory=${REPO_DIR}" "$@"
}

# ---------------------------------------------------------------------------
# 6. 前提確認 / リポジトリ確認
# ---------------------------------------------------------------------------
preflight() {
  require_command git

  # Git 作業ツリーであることを確認
  if ! git_r rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "Git の作業ツリーではありません: ${REPO_DIR}"
  fi

  # トップレベルを対象にそろえる
  local toplevel
  toplevel="$(git_r rev-parse --show-toplevel)"
  if [[ "${toplevel}" != "${REPO_DIR}" ]]; then
    log_warn "指定ディレクトリは Git のトップレベルではありません。トップレベルを対象にします。"
    log_warn "  指定        : ${REPO_DIR}"
    log_warn "  トップレベル: ${toplevel}"
    REPO_DIR="${toplevel}"
  fi
  log_info "対象リポジトリ: ${REPO_DIR}"

  # 未完了の merge / rebase / cherry-pick が残っていないか先に確認する。
  # （rebase 中は detached HEAD になるため、ブランチ判定より前に検出して
  #   分かりやすいメッセージを出す。残っていると取り込みできない。）
  if is_in_progress; then
    die "未完了の merge/rebase/cherry-pick が残っています。先に解決（git status 参照）するか、" \
        "'git -C \"${REPO_DIR}\" merge --abort' / 'rebase --abort' で中断してから再実行してください。"
  fi

  # 取り込み先ブランチを確定（未指定なら現在のブランチ）
  local current_branch
  current_branch="$(git_r rev-parse --abbrev-ref HEAD)"
  if [[ "${current_branch}" == "HEAD" ]]; then
    die "detached HEAD 状態です。feature ブランチを checkout してから実行してください。"
  fi
  if [[ -z "${FEATURE_BRANCH}" ]]; then
    FEATURE_BRANCH="${current_branch}"
  elif [[ "${FEATURE_BRANCH}" != "${current_branch}" ]]; then
    log_info "ブランチ '${FEATURE_BRANCH}' に切り替えます（現在: ${current_branch}）。"
    run git_r switch "${FEATURE_BRANCH}" \
      || die "ブランチ '${FEATURE_BRANCH}' への切り替えに失敗しました。"
  fi

  # 取り込み先が main そのものでないことを確認（事故防止）
  if [[ "${FEATURE_BRANCH}" == "${MAIN_BRANCH}" ]]; then
    die "取り込み先が ${MAIN_BRANCH} です。これは feature/hotfix ブランチ向けスクリプトです。" \
        "（main 自体の同期は codecommit-clean-pull.sh を利用してください）"
  fi
  log_info "取り込み先ブランチ: ${FEATURE_BRANCH}"
  log_info "取り込み元ブランチ: ${REMOTE}/${MAIN_BRANCH}"

  # remote の存在確認
  if ! git_r remote get-url "${REMOTE}" >/dev/null 2>&1; then
    die "リモート '${REMOTE}' が設定されていません。git remote -v で確認してください。"
  fi
  local remote_url
  remote_url="$(git_r remote get-url "${REMOTE}")"
  log_info "リモート ${REMOTE}: ${remote_url}"

  # grc(git-remote-codecommit)形式の remote なら依存コマンドを確認
  if [[ "${remote_url}" == codecommit::* ]]; then
    require_command aws
    require_command git-remote-codecommit
    log_debug "grc 形式の remote を検出（aws / git-remote-codecommit 確認済み）。"
  fi
}

# 進行中の merge / rebase / cherry-pick を検出する
is_in_progress() {
  local git_dir
  git_dir="$(git_r rev-parse --git-dir)"
  case "${git_dir}" in
    /*) : ;;
    *)  git_dir="${REPO_DIR}/${git_dir}" ;;
  esac
  if git_r rev-parse --verify --quiet MERGE_HEAD >/dev/null; then return 0; fi
  if [[ -d "${git_dir}/rebase-merge" || -d "${git_dir}/rebase-apply" ]]; then return 0; fi
  if [[ -f "${git_dir}/CHERRY_PICK_HEAD" ]]; then return 0; fi
  return 1
}

# ---------------------------------------------------------------------------
# 7. リモート最新の取得
# ---------------------------------------------------------------------------
fetch_remote() {
  log_info "リモートから fetch します（${REMOTE} ${MAIN_BRANCH}, --prune）..."
  # single-branch clone でも確実に main を取得できるよう、ブランチを明示して fetch
  if ! git_r fetch --prune "${REMOTE}" "${MAIN_BRANCH}"; then
    die "fetch に失敗しました。ネットワーク / 認証（IAM 権限 codecommit:GitPull 等）を確認してください。"
  fi

  if ! git_r rev-parse --verify --quiet "refs/remotes/${REMOTE}/${MAIN_BRANCH}" >/dev/null; then
    die "リモートブランチ '${REMOTE}/${MAIN_BRANCH}' が見つかりません。--main / --remote を確認してください。"
  fi
  local remote_head
  remote_head="$(git_r rev-parse "${REMOTE}/${MAIN_BRANCH}")"
  log_info "${REMOTE}/${MAIN_BRANCH} の最新コミット: ${remote_head:0:12}"
}

# ---------------------------------------------------------------------------
# 8. 取り込み要否の判定
#   - origin/main が既に feature の履歴に含まれていれば取り込み不要
# ---------------------------------------------------------------------------
already_up_to_date() {
  # origin/main が HEAD の祖先なら、main の内容は既に取り込み済み
  git_r merge-base --is-ancestor "${REMOTE}/${MAIN_BRANCH}" HEAD 2>/dev/null
}

# ---------------------------------------------------------------------------
# 9. ローカル main を origin/main に fast-forward 追従させる（任意・非致命的）
#   - チェックアウトせずに ref を更新できる場合のみ ff 更新する
# ---------------------------------------------------------------------------
update_local_main() {
  [[ "${UPDATE_LOCAL_MAIN}" == "true" ]] || return 0
  # ローカル main が存在しなければスキップ
  git_r rev-parse --verify --quiet "refs/heads/${MAIN_BRANCH}" >/dev/null || return 0
  # feature にいるので、非チェックアウトの main を fetch で ff 更新する
  # （fast-forward 不可なら警告のみ。main 自体は本スクリプトの対象外）
  if git_r fetch "${REMOTE}" "${MAIN_BRANCH}:${MAIN_BRANCH}" >/dev/null 2>&1; then
    log_debug "ローカル ${MAIN_BRANCH} を ${REMOTE}/${MAIN_BRANCH} に ff 追従しました。"
  else
    log_debug "ローカル ${MAIN_BRANCH} の ff 追従はスキップ（非 ff のため。問題ありません）。"
  fi
}

# ---------------------------------------------------------------------------
# 10. ドライラン: 何が取り込まれるか / コンフリクト見込みを表示
# ---------------------------------------------------------------------------
show_dry_run() {
  log_info "=== DRY-RUN（実際の取り込みは行いません） ==="

  log_info "--- 現在の作業ツリーの状態 (git status --short) ---"
  git_r status --short || true

  if already_up_to_date; then
    log_info "${REMOTE}/${MAIN_BRANCH} は既に '${FEATURE_BRANCH}' に取り込み済みです。取り込み不要。"
    exit 0
  fi

  log_info "--- 取り込まれる main 側のコミット (${FEATURE_BRANCH}..${REMOTE}/${MAIN_BRANCH}) ---"
  git_r --no-pager log --oneline "${FEATURE_BRANCH}..${REMOTE}/${MAIN_BRANCH}" || true

  log_info "--- 変更されるファイル (git diff --stat) ---"
  git_r --no-pager diff --stat "${FEATURE_BRANCH}...${REMOTE}/${MAIN_BRANCH}" || true

  # コンフリクト見込みを merge-tree で事前判定（作業ツリーは一切変更しない）
  predict_conflicts

  log_warn "DRY-RUN: 上記の main 側変更を取り込む必要があります（merge/rebase を実行してください）。"
  exit 2
}

# merge-tree でコンフリクトを事前予測する（破壊なし）。
# git 2.38+ の `merge-tree --write-tree` を優先。使えなければ予測をスキップ。
predict_conflicts() {
  local base ours theirs
  base="$(git_r merge-base HEAD "${REMOTE}/${MAIN_BRANCH}" 2>/dev/null || true)"
  ours="$(git_r rev-parse HEAD)"
  theirs="$(git_r rev-parse "${REMOTE}/${MAIN_BRANCH}")"
  [[ -n "${base}" ]] || { log_debug "merge-base が取得できないため予測をスキップ。"; return 0; }

  log_info "--- コンフリクト見込みの事前判定 (merge-tree) ---"
  local out rc
  if out="$(git_r merge-tree --write-tree --name-only "${ours}" "${theirs}" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi

  if [[ "${rc}" -eq 0 ]]; then
    log_success "事前判定: コンフリクトは検出されませんでした（クリーンに取り込める見込み）。"
  elif [[ "${rc}" -eq 1 ]]; then
    # merge-tree --write-tree の出力構造:
    #   1 行目        : 生成された tree の OID
    #   2 行目〜空行   : 競合ファイル名（--name-only）
    #   空行以降       : "Auto-merging ..." 等の情報メッセージ
    # ここでは 2 行目から最初の空行までを競合ファイル名として取り出す。
    local files
    files="$(printf '%s\n' "${out}" | awk 'NR>1{ if ($0=="") exit; print }')"
    log_warn "事前判定: 以下のファイルでコンフリクトが見込まれます:"
    printf '%s\n' "${files}" | sed 's/^/    /' >&2
  else
    log_debug "merge-tree --write-tree が使えないため予測をスキップ（古い git）。"
  fi
}

# ---------------------------------------------------------------------------
# 11. 作業ツリーの未コミット変更の扱い
# ---------------------------------------------------------------------------
STASHED="false"
ensure_clean_or_stash() {
  if [[ -z "$(git_r status --porcelain)" ]]; then
    return 0
  fi
  if [[ "${AUTOSTASH}" == "true" ]]; then
    log_info "未コミットの変更を一時退避します（git stash）..."
    if git_r stash push --include-untracked -m "sync_main_to_feature: autostash"; then
      STASHED="true"
    else
      die "stash に失敗しました。手動でコミット or 退避してから再実行してください。"
    fi
  else
    log_error "未コミットの変更があります。取り込み前にコミットするか、--autostash を指定してください。"
    git_r status --short >&2 || true
    die "作業ツリーがクリーンではありません。"
  fi
}

# 退避した変更を復元する（取り込み成功後）
restore_stash() {
  [[ "${STASHED}" == "true" ]] || return 0
  log_info "退避した変更を復元します（git stash pop）..."
  if git_r stash pop; then
    log_success "退避していた変更を復元しました。"
  else
    log_warn "stash pop でコンフリクトが発生しました。'git status' を確認し、手動で解決してください。"
    log_warn "退避内容は 'git stash list' に残っています。"
  fi
}

# ---------------------------------------------------------------------------
# 12. コンフリクト解消ガイド
#   - 取り込み（merge / rebase）でコンフリクトが起きたときに表示する。
#   - リポジトリは「解決待ち」状態のまま残し、ユーザーが解決できるよう導く。
# ---------------------------------------------------------------------------
guide_conflict() {
  local mode="$1"   # "merge" または "rebase"
  local conflicted
  conflicted="$(git_r diff --name-only --diff-filter=U || true)"

  echo >&2
  log_error "コンフリクトが発生しました（取り込み方式: ${mode}）。"
  log_warn  "リポジトリは「解決待ち」状態です。以下の手順で解消してください。"
  echo >&2

  log_warn "■ 競合しているファイル:"
  if [[ -n "${conflicted}" ]]; then
    printf '%s\n' "${conflicted}" | sed 's/^/    /' >&2
  else
    log_warn "    （git status で確認してください）"
  fi
  echo >&2

  cat >&2 <<'GUIDE'
■ 競合マーカーの読み方:
    ファイル内に以下のマーカーが挿入されています。

      <<<<<<< HEAD            ← ここから下が「自分側(feature)」の内容
      （feature 側の行）
      =======                 ← 区切り
      （main 側の行）
      >>>>>>> origin/main     ← ここまでが「取り込む側(main)」の内容

    どちらを採用するか / 両方を組み合わせるかを決め、3 つのマーカー行
    （<<<<<<< / ======= / >>>>>>>）を必ず削除してファイルを正しい状態にします。

■ 解消の手順:
    1) 競合ファイルを編集して内容を確定する
         - エディタで開いて手作業で統合する、または
         - GUI/マージツールを使う:   git mergetool
         - 片側を丸ごと採用する場合:
             自分側(feature)を採用:   git checkout --ours  <file>
             main 側を採用:           git checkout --theirs <file>
           （rebase 中は ours/theirs の意味が逆になる点に注意。
             rebase では "ours"=main側, "theirs"=feature側 です）
    2) 解決したファイルをステージする:
         git add <file>            （全部なら: git add -A）
GUIDE

  if [[ "${mode}" == "rebase" ]]; then
    cat >&2 <<GUIDE
    3) リベースを継続する:
         git -C "${REPO_DIR}" rebase --continue
       （まだ競合が残るコミットがあれば 1〜3 を繰り返します）

■ やり直し / 中断:
    - 今回の解決を取り消して最初からやり直す:   git -C "${REPO_DIR}" rebase --abort
      （feature ブランチは取り込み前の状態に戻ります）
GUIDE
  else
    cat >&2 <<GUIDE
    3) マージコミットを作成して完了する:
         git -C "${REPO_DIR}" commit            （既定のマージメッセージで確定）

■ やり直し / 中断:
    - 今回のマージを取り消して取り込み前に戻す:  git -C "${REPO_DIR}" merge --abort
GUIDE
  fi

  cat >&2 <<GUIDE

■ 進捗の確認:
    git -C "${REPO_DIR}" status          競合ファイル / 残作業を確認
    git -C "${REPO_DIR}" diff            競合差分を確認

■ 解決後、もう一度本スクリプトを実行すると最新状態を再確認できます:
    ${SCRIPT_NAME} --repo-dir "${REPO_DIR}" --dry-run
GUIDE
  echo >&2

  # 対話環境なら、その場で「中断するか/手動解決を続けるか」を選べるようにする
  if [[ -t 0 && "${ASSUME_YES}" != "true" ]]; then
    if confirm "今回の取り込みを中断（abort）して取り込み前の状態に戻しますか?"; then
      if [[ "${mode}" == "rebase" ]]; then
        run git_r rebase --abort || true
      else
        run git_r merge --abort || true
      fi
      log_info "取り込みを中断しました。feature ブランチは取り込み前の状態です。"
      # 中断した場合、autostash していた変更は戻しておく
      restore_stash
      exit 3
    fi
    log_info "解決待ち状態のままにします。上記手順に従って解消してください。"
  fi

  # autostash していた場合、解決待ち状態では pop できないため案内のみ
  if [[ "${STASHED}" == "true" ]]; then
    log_warn "注意: --autostash で退避した変更は 'git stash list' に残っています。"
    log_warn "      コンフリクト解決・コミット後に 'git -C \"${REPO_DIR}\" stash pop' で復元してください。"
  fi

  exit 3
}

# ---------------------------------------------------------------------------
# 13. 取り込み本体（merge / rebase）
# ---------------------------------------------------------------------------
do_sync() {
  local old_head new_head
  old_head="$(git_r rev-parse HEAD)"

  if [[ "${USE_REBASE}" == "true" ]]; then
    log_info "'${FEATURE_BRANCH}' を ${REMOTE}/${MAIN_BRANCH} の上に rebase します..."
    if ! git_r rebase "${REMOTE}/${MAIN_BRANCH}"; then
      guide_conflict "rebase"   # exit 3
    fi
  else
    log_info "'${FEATURE_BRANCH}' に ${REMOTE}/${MAIN_BRANCH} を merge します..."
    # --no-edit: 既定のマージメッセージで確定（コンフリクト時は失敗するのでガイドへ）
    if ! git_r merge --no-edit "${REMOTE}/${MAIN_BRANCH}"; then
      guide_conflict "merge"    # exit 3
    fi
  fi

  new_head="$(git_r rev-parse HEAD)"
  log_info "取り込み前 HEAD: ${old_head:0:12}"
  log_info "取り込み後 HEAD: ${new_head:0:12}"
}

# ---------------------------------------------------------------------------
# 14. 取り込み結果の検証
# ---------------------------------------------------------------------------
verify_merged() {
  if already_up_to_date; then
    log_success "検証 OK: ${REMOTE}/${MAIN_BRANCH} の内容が '${FEATURE_BRANCH}' に取り込まれています。"
  else
    log_warn "検証: ${REMOTE}/${MAIN_BRANCH} がまだ '${FEATURE_BRANCH}' の祖先になっていません。"
    log_warn "  rebase でローカルに先行コミットがある場合などは想定どおりのことがあります。"
  fi
}

# ---------------------------------------------------------------------------
# 15. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight
  fetch_remote
  update_local_main

  # 既に取り込み済みなら何もしない
  if already_up_to_date; then
    log_success "既に最新です: ${REMOTE}/${MAIN_BRANCH} は '${FEATURE_BRANCH}' に取り込み済みです。"
    exit 0
  fi

  # ドライランはここで終了（show_dry_run 内で exit）
  if [[ "${DRY_RUN}" == "true" ]]; then
    show_dry_run
  fi

  # 取り込み内容の事前提示
  log_info "--- 取り込まれる main 側コミット (${FEATURE_BRANCH}..${REMOTE}/${MAIN_BRANCH}) ---"
  git_r --no-pager log --oneline "${FEATURE_BRANCH}..${REMOTE}/${MAIN_BRANCH}" || true
  echo

  # 取り込み方式の確認
  local method="merge"; [[ "${USE_REBASE}" == "true" ]] && method="rebase"
  log_warn "これから ${REMOTE}/${MAIN_BRANCH} の最新を '${FEATURE_BRANCH}' に ${method} で取り込みます。"
  log_warn "  対象ディレクトリ: ${REPO_DIR}"
  if [[ "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
      confirm "実行しますか?" || die "ユーザーによって中止されました。"
    else
      die "非対話環境です。実行するには -y/--yes を指定してください（確認には --dry-run）。"
    fi
  fi

  # 未コミット変更の退避（必要時）
  ensure_clean_or_stash

  # 取り込み（コンフリクト時は guide_conflict 内で exit 3）
  do_sync

  # 退避していた変更を復元
  restore_stash

  verify_merged
  log_success "完了: ${REPO_DIR} の '${FEATURE_BRANCH}' に ${REMOTE}/${MAIN_BRANCH} の最新を取り込みました。"
}

main "$@"
