# MissionX

macOS Mission Control에서 창 썸네일 위에 커서를 올리면 닫기 버튼을 표시하는 메뉴 막대 앱입니다.

## 다운로드

[Apple Silicon용 앱 다운로드](https://github.com/kub938/MissionX/raw/refs/heads/main/downloads/MissionX-v0.6.1-macos-arm64.zip) · [릴리스 안내](https://github.com/kub938/MissionX/releases/latest)

현재 버전: **0.6.1** · 닫기 버튼 크기: **22포인트**

## 사용 방법

1. 다운로드한 ZIP을 풀고 MissionX.app을 고정 위치에 옮겨 실행합니다.
2. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 MissionX를 허용합니다.
3. Mission Control을 열고 창 썸네일 위에 커서를 올립니다.
4. 왼쪽 위 테두리에 표시되는 빨간 ×를 누르면 해당 창의 닫기 버튼을 실행합니다.

저장 확인 대화상자는 원래 앱의 일반적인 창 닫기 동작을 따릅니다. 처음에는 저장할 내용 없는 창으로 확인하세요.

배포 앱은 Apple Silicon(arm64)용이며 로컬 임시 서명 상태입니다. Apple 공증은 없습니다. 새 버전을 설치했을 때 권한이 이어지지 않으면 손쉬운 사용 항목을 새 앱으로 갱신하세요. 기존 MissionX를 종료한 뒤 새 버전을 실행하세요.

## 기능

- macOS 스타일의 22포인트 빨간 원과 가는 × 표시
- 썸네일 왼쪽 위 테두리에 버튼 배치
- 창별 패널과 애니메이션 없는 표시 전환
- 앱별 창 정보 캐시 및 별도 커서 처리
- Chrome 창 제목의 제품명 접미사 처리
- Finder 일반 폴더 창과 데스크탑 등 특수 표면 구분
- 클릭 시 실제 대상 창과 닫기 액션 재확인
- 메뉴에서 접근성 권한 확인, 일시정지, 진단 저장

## 소스에서 빌드

macOS 13 이상 및 Xcode Command Line Tools가 필요합니다. Intel Mac에서는 직접 빌드하세요.

```sh
git clone https://github.com/kub938/MissionX.git
cd MissionX
chmod +x build.sh
./build.sh
open dist/MissionX.app
```

빌드 스크립트는 앱을 로컬 서명하고 54개 자체 검사를 실행합니다. 외부 패키지 의존성은 없습니다. `--disable-sandbox`는 로컬 Swift 패키지 빌드에만 적용되며 macOS 접근성 권한을 우회하지 않습니다.

## 검사와 진단

```sh
dist/MissionX.app/Contents/MacOS/MissionX --self-test
dist/MissionX.app/Contents/MacOS/MissionX --diagnose
```

문제가 발생하면 메뉴의 **5초 후 진단 저장…**을 선택하고 즉시 Mission Control을 여세요. 보고서에는 앱과 창 제목이 포함됩니다. 공개 이슈에 첨부하기 전에 개인 정보를 제거하세요. 보고서는 자동으로 업로드되지 않습니다.

개발용으로 기존 진단 구조를 오프라인에서 재생할 수도 있습니다.

```sh
dist/MissionX.app/Contents/MacOS/MissionX --replay-diagnostic /path/to/MissionX-diagnostics.txt
```

## 제한 사항

Mission Control의 접근성 트리와 식별자는 문서화된 안정 API가 아닙니다. macOS 업데이트에 따라 동작이 바뀔 수 있습니다. 27.0.1에서 제공된 진단 구조를 바탕으로 개발했습니다.

- 같은 앱의 중복 제목이나 축약 제목은 잘못된 창을 닫지 않도록 거부합니다.
- 특수 창, 전체화면 Space 상단 타일, 다른 Space 및 Stage Manager는 지원을 보장하지 않습니다.
- 접근성을 제대로 제공하지 않는 앱에는 버튼이 나타나지 않을 수 있습니다.
- 33ms는 커서 처리 주기이며 실제 표시 지연을 측정한 값은 아닙니다.
- 54개 로직 검사와 오프스크린 버튼 렌더링을 확인했습니다. 모든 앱·모니터·제스처 조합의 실기 검증을 마친 것은 아닙니다.

## 개인정보

네트워크 요청, 화면 녹화, 자동 시작, 강제 종료 또는 합성 키 입력을 사용하지 않습니다. 다른 앱의 창 메타데이터를 읽고 닫기 버튼을 누르기 위해 손쉬운 사용 권한을 사용합니다.
