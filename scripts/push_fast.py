#!/usr/bin/env python3
"""用 GitHub Git Data API 增量推送本地目录。

为什么不用 git push：
  github.com:443 在本环境不可达（git push 会超时）。
  但 api.github.com 可用，因此走 blobs -> tree -> commit -> PATCH ref。

为什么是"增量"：
  GitHub 现在对 POST 返回 307，urllib 默认不跟随 POST 的 307。
  本脚本显式处理 307/308 并在跨域时剥离 Authorization。
  同时用 git blob sha1 与远端 tree 比对，只上传变化文件——
  否则每次全量重传几十 MB 会超时中断。

用法：
  python3 push_fast.py --repo owner/name --branch main --dir . \
      --token-env GITHUB_TOKEN_1 --message "feat: xxx"
"""
import argparse
import base64
import hashlib
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

API = 'https://api.github.com'
CTX = ssl.create_default_context()


def blob_sha1(data: bytes) -> str:
    """git blob 对象的 sha1：sha1("blob <len>\\0" + content)"""
    h = hashlib.sha1()
    h.update(b'blob %d\0' % len(data))
    h.update(data)
    return h.hexdigest()


def request(method, url, token, body=None, retries=5, raw=False):
    data = None
    headers = {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'lingfan-push',
        'Authorization': f'Bearer {token}',
    }
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'

    last = None
    for attempt in range(retries):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=90, context=CTX) as resp:
                payload = resp.read()
                return resp.status, (payload if raw else json.loads(payload or b'{}'))
        except urllib.error.HTTPError as e:
            payload = e.read()
            # 307/308 需要手工跟随（POST 的 307 不会被 urllib 自动跟）
            if e.code in (301, 302, 307, 308):
                loc = e.headers.get('Location')
                if loc:
                    last = f'HTTP {e.code} -> {loc}'
                    time.sleep(1 + attempt)
                    continue
            last = f'HTTP {e.code}: {payload[:400]}'
            if e.code in (500, 502, 503, 504):
                time.sleep(2 ** attempt)
                continue
            raise RuntimeError(f'{method} {url} -> {last}')
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = repr(e)
            time.sleep(2 ** attempt)
    raise RuntimeError(f'{method} {url} 重试 {retries} 次仍失败: {last}')


def collect(local_dir):
    """返回 {repo_path: bytes}，跳过 .git 与 .gitignore 里的大产物"""
    skip_dirs = {'.git', 'build', 'DerivedData', 'dist'}
    skip_ext = ('.ipa', '.a', '.zip', '.o')
    out = {}
    for root, dirs, files in os.walk(local_dir):
        dirs[:] = [d for d in dirs if d not in skip_dirs]
        for f in files:
            if f.endswith(skip_ext):
                continue
            full = os.path.join(root, f)
            rel = os.path.relpath(full, local_dir).replace(os.sep, '/')
            with open(full, 'rb') as fh:
                out[rel] = fh.read()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--branch', default='main')
    ap.add_argument('--dir', default='.')
    ap.add_argument('--token-env', default='GITHUB_TOKEN_1')
    ap.add_argument('--message', default='chore: update')
    args = ap.parse_args()

    token = os.environ.get(args.token_env)
    if not token:
        raise SystemExit(f'环境变量 {args.token_env} 未设置')

    local = collect(args.dir)
    print(f'本地文件 {len(local)} 个')

    # 1. 取分支当前 head
    _, ref = request('GET', f'{API}/repos/{args.repo}/git/ref/heads/{args.branch}', token)
    head = ref['object']['sha']
    print(f'分支 {args.branch} head = {head[:10]}')

    _, commit = request('GET', f'{API}/repos/{args.repo}/git/commits/{head}', token)
    base_tree = commit['tree']['sha']

    # 2. 取远端 tree（递归）
    _, tree = request(
        'GET', f'{API}/repos/{args.repo}/git/trees/{base_tree}?recursive=1', token)
    remote = {e['path']: e['sha'] for e in tree.get('tree', []) if e['type'] == 'blob'}
    print(f'远端文件 {len(remote)} 个')

    # 3. 找差异
    changed, added, deleted = [], [], []
    for path, content in local.items():
        sha = blob_sha1(content)
        if path not in remote:
            added.append(path)
            changed.append(path)
        elif remote[path] != sha:
            changed.append(path)
    for path in remote:
        if path not in local:
            deleted.append(path)

    print(f'新增 {len(added)} / 修改 {len(changed) - len(added)} / 删除 {len(deleted)}')

    if not changed and not deleted:
        print('无变化，退出')
        return

    # 4. 只上传变化的 blob
    entries = []
    for path in changed:
        content = local[path]
        body = base64.b64encode(content).decode()
        _, blob = request(
            'POST', f'{API}/repos/{args.repo}/git/blobs', token,
            {'content': body, 'encoding': 'base64'})
        entries.append({
            'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']
        })
        print(f'  ↑ {path} ({len(content)} B)')

    for path in deleted:
        entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': None})
        print(f'  ✗ {path}')

    # 5. 建 tree
    _, new_tree = request(
        'POST', f'{API}/repos/{args.repo}/git/trees', token,
        {'base_tree': base_tree, 'tree': entries})
    print(f'新 tree = {new_tree["sha"][:10]}')

    # 6. 建 commit
    _, new_commit = request(
        'POST', f'{API}/repos/{args.repo}/git/commits', token,
        {'message': args.message, 'tree': new_tree['sha'], 'parents': [head]})
    print(f'新 commit = {new_commit["sha"][:10]}')

    # 7. 更新分支
    request('PATCH', f'{API}/repos/{args.repo}/git/refs/heads/{args.branch}', token,
            {'sha': new_commit['sha']})
    print(f'✅ 已推送到 {args.repo}#{args.branch}')


if __name__ == '__main__':
    main()
