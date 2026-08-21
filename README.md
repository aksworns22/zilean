# Zilean

Zilean은 타이머와 피드백을 채팅 흐름으로 연결하는 macOS용 시간 관리 앱입니다.

## 개발 환경

- macOS 26.5 이상
- Xcode 26.5
- 설치 및 인증을 마친 Codex CLI

Zilean은 별도의 API 키를 저장하지 않고 로컬 [`codex app-server`](https://developers.openai.com/codex/app-server)를 실행합니다. 먼저 터미널에서 다음 명령으로 설치 경로와 인증 상태를 확인합니다.

```bash
command -v codex
codex login status
```

앱은 `CODEX_PATH`, 실행 환경의 `PATH`, 일반적인 설치 경로, 로그인 셸 순서로 `codex` 실행 파일을 찾습니다.

## 프로젝트 실행

1. `zilean.xcodeproj`를 Xcode 26.5에서 엽니다.
2. 공유된 `zilean` scheme과 `My Mac` 실행 대상을 선택합니다.
3. Run 버튼을 누르거나 `Command-R`을 입력합니다.

## 로컬 Codex 대화

1. `새 작업`을 눌러 Codex가 읽을 작업 디렉터리를 지정합니다.
2. 해당 디렉터리에서 대화가 생성되면 메시지를 입력하고 전송합니다.
3. 스트리밍되는 응답을 확인합니다.

연결 또는 프로토콜 오류가 발생하면 입력창 위 오류 배너의 안내를 확인하고 `연결 재시도`를 누릅니다. 현재 최소 흐름은 승인 요청 없이 읽기 전용 sandbox에서 동작합니다.

앱은 Codex app-server를 시작할 때 Zilean의 로컬 STDIO MCP 서버를 함께 연결합니다. MCP 런타임 파일은 `~/Library/Application Support/Zilean/MCP`에 두며, 사용자의 전역 Codex 설정 파일은 변경하지 않습니다.

## 명령줄 빌드

저장소 루트에서 다음 명령을 실행합니다.

```bash
xcodebuild \
  -project zilean.xcodeproj \
  -scheme zilean \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

## 테스트

단위 테스트만 실행하려면 다음 명령을 사용합니다.

```bash
xcodebuild \
  -project zilean.xcodeproj \
  -scheme zilean \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:zileanTests \
  test
```

UI 테스트를 포함한 전체 테스트는 `-only-testing:zileanTests` 옵션을 제거해 실행합니다.

## app-server 종료 수동 QA

1. 앱 실행 전에 `pgrep -fl 'codex app-server'` 결과를 기록합니다. 다른 Codex 클라이언트가 만든 프로세스가 있을 수 있으므로 PID를 함께 확인합니다.
2. Zilean에서 폴더 선택, 새 대화, 메시지 전송, 응답 완료까지 진행합니다.
3. `Command-Q`로 Zilean을 종료합니다.
4. `pgrep -fl 'codex app-server'`를 다시 실행합니다.
5. 1단계와 비교해 Zilean이 시작한 새 app-server 프로세스가 남지 않았는지 확인합니다.

빌드 산출물과 Xcode 사용자별 설정은 `.gitignore`에 의해 버전 관리에서 제외됩니다.

## 질리언이 질리 없어!

![질리언이 질리 없어!](docs/zilean-is-not-boring.png)
