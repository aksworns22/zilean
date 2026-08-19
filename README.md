# Zilean

Zilean은 타이머와 피드백을 채팅 흐름으로 연결하는 macOS용 시간 관리 앱입니다.

## 개발 환경

- macOS 26.5 이상
- Xcode 26.5

별도의 외부 서비스, API 키 또는 추가 패키지 설치는 필요하지 않습니다.

## 프로젝트 실행

1. `zilean.xcodeproj`를 Xcode 26.5에서 엽니다.
2. 공유된 `zilean` scheme과 `My Mac` 실행 대상을 선택합니다.
3. Run 버튼을 누르거나 `Command-R`을 입력합니다.

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

빌드 산출물과 Xcode 사용자별 설정은 `.gitignore`에 의해 버전 관리에서 제외됩니다.
