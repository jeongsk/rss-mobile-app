# 내 RSS

개인용 iPhone·iPad RSS 리더. Swift 6 + SwiftUI + SwiftData, iOS 18 이상.

저장소: https://github.com/jeongsk/rss-mobile-app

## 기능

| 기능 | 내용 |
|---|---|
| Feedly 가져오기 | Feedly에서 내보낸 OPML 파일을 폴더 구조 그대로 가져온다. OPML 내보내기도 지원 |
| 피드 추가 | 블로그 주소만 넣어도 RSS/Atom 주소를 찾아 준다 |
| 목록 레이아웃 | 리스트, 매거진, 그리드, 제목만 (폴더·피드마다 따로 기억) |
| 오프라인 전체 본문 | 요약만 있는 피드는 원문 페이지에서 본문을 추출해 저장. 본문 이미지도 저장 |
| 리더 ↔ 원본 웹 | 리더 화면 오른쪽 위 나침반 버튼. 원본 웹 하단의 **"이 페이지를 리더로 저장"**으로 지금 보는 페이지를 오프라인 본문으로 저장 (로그인·브라우저 확인이 필요한 사이트용) |
| 소개 사이트 | GeekNews는 원문 기사 링크와 댓글(Hacker News 의견 포함)을 함께 표시 |
| 읽기 스타일 | 테마 5종, 글자 크기, 줄·문단 간격, 여백, 양쪽 정렬, 사용자 폰트(TTF·OTF) |
| 번역 | Apple 기기 내 번역(무료, 오프라인 가능). 원문만 / 원문+번역 / 번역만 |
| 하이라이트·메모 | 글자를 길게 눌러 선택 → 하이라이트 또는 메모. 모아보기, Markdown 내보내기 |
| 읽어주기(TTS) | 문장 표시, 속도·음성 선택, 번역문 읽기, 읽지 않은 글 연속 듣기, 잠금 화면 제어 |
| 기기 간 동기화 | iCloud Drive의 폴더 하나로 아이폰·아이패드 동기화 |
| 백그라운드 갱신 | 약 30분 간격 새 글 받기, 쉬는 시간에 남은 본문 저장 |

## 내 아이폰에 설치하기 (무료 Apple ID)

1. 준비
   ```sh
   brew install xcodegen
   git clone https://github.com/jeongsk/rss-mobile-app.git
   cd rss-mobile-app
   xcodegen generate
   open RSSReader.xcodeproj
   ```
2. Xcode > Settings > Accounts에서 Apple ID를 추가한다.
3. `project.yml` 맨 위 `settings.base`의 `APP_BUNDLE_ID`를 나만의 값으로 바꾼다. 앱, 위젯(`<번들 ID>.Widget`), App Group(`group.<번들 ID>`)이 모두 이 값에서 만들어진다.
   ```yaml
   APP_BUNDLE_ID: com.<내이름>.RSSReader
   ```
   팀 ID는 저장소에 넣지 않고 환경변수 `DEVELOPMENT_TEAM`으로 준다. Xcode > Signing & Capabilities에서 Personal Team을 고르면 보이는 값이다.
   ```sh
   echo 'export DEVELOPMENT_TEAM=<팀 ID>' >> ~/.zshrc   # 한 번만
   source ~/.zshrc && xcodegen generate
   ```
   (Xcode에서 직접 바꿔도 되지만 `xcodegen generate`를 다시 실행하면 사라진다. `build.sh`, `test.sh`도 매번 다시 생성한다.)
4. 아이폰을 연결하고 아이폰의 설정 > 개인정보 보호 및 보안 > **개발자 모드**를 켠다.
5. Xcode에서 실행 대상을 내 아이폰으로 고르고 ▶︎ 실행.
6. 처음 실행 시 아이폰 설정 > 일반 > VPN 및 기기 관리에서 내 개발자 인증서를 신뢰한다.

**무료 계정 제약**: 설치한 앱은 **7일 뒤 실행되지 않는다.** Xcode에서 다시 ▶︎ 실행하면 데이터는 그대로 두고 다시 7일간 쓸 수 있다. 무료 계정은 iCloud(CloudKit) 기능을 쓸 수 없어서, 동기화는 iCloud Drive 폴더 방식으로 구현했다.

## 처음 설정

1. **Feedly 구독 옮기기**: 사이드바 `+` > Feedly / OPML 가져오기 > "Feedly OPML 내보내기 열기"에서 파일을 받은 뒤 그 파일을 선택한다.
2. **동기화**: 설정 > iCloud Drive 동기화 폴더 선택 > iCloud Drive에 `내 RSS 동기화` 같은 폴더를 만들어 선택한다. 아이패드에서도 **같은 폴더**를 선택한다. 두 번째 기기는 OPML을 다시 가져오지 말고 폴더만 선택하면 구독이 넘어온다.
3. **번역 언어**: 처음 번역할 때 언어 모델 다운로드 창이 뜬다. 설정 > 앱 > 번역에서 미리 받아 둘 수도 있다.
4. **고품질 음성**: 설정 > 손쉬운 사용 > 읽기 및 말하기 콘텐츠 > 음성에서 한국어 '고품질' 음성을 받으면 앱 설정의 음성 목록에 나타난다.

## 실제 기기에서 확인해야 할 것

시뮬레이터에서 확인할 수 없어서 기기에서 직접 봐야 하는 항목이다.

- [ ] 번역 (Apple 번역은 시뮬레이터 미지원) — 원문+번역, 번역만, 자동 번역
- [ ] iCloud Drive 폴더를 통한 아이폰 ↔ 아이패드 동기화
- [ ] 백그라운드 갱신 (iOS가 실행 시점을 정한다. 앱을 자주 쓸수록 자주 실행된다)
- [ ] TTS 백그라운드 재생, 잠금 화면·이어폰 제어, 고품질 음성
- [ ] 파일 앱에서 폰트 파일 추가
- [ ] Feedly에서 받은 `.opml` 파일이 파일 선택 창(다운로드, iCloud Drive)에서 선택되는지
- [ ] 7일 뒤 앱이 열리지 않으면 Xcode에서 다시 실행
- [ ] GeekNews처럼 브라우저 확인을 요구하는 사이트: 원본 웹에서 확인을 통과한 뒤 "이 페이지를 리더로 저장"이 되는지

## 개발

```sh
./build.sh                  # 시뮬레이터 빌드
./test.sh                   # 단위 테스트 + UI 테스트
./test.sh -only-testing:RSSReaderTests
./run.sh "iPhone 17" -demo  # 샘플 구독을 넣고 실행 (DEBUG)
TEST_RUNNER_LIVE_TESTS=1 ./test.sh -only-testing:RSSReaderTests/LiveExtractionTests  # 실제 사이트 본문 추출 점검
```

DEBUG 실행 인자 (캡처·점검용): `-demo`, `-openFirst`, `-layout list|magazine|grid|titles`, `-sidebar`, `-highlights`, `-sheet addFeed|importOPML|settings`, `-theme`, `-font`, `-web`, `-style`, `-speak`, `-fakeTranslate -display both|translated`, `-demoHighlight`, `-syncFolder <경로>`.

### 구조

| 경로 | 내용 |
|---|---|
| `RSSReader/Models/Models.swift` | SwiftData 모델 (Folder, Feed, Article, Highlight, Tombstone) |
| `RSSReader/Services/FeedParser.swift`, `OPML.swift` | RSS 2.0 / RSS 1.0 / Atom / OPML 파서 |
| `RSSReader/Services/ContentExtractor.swift` | Readability 방식 본문 추출 (SwiftSoup) |
| `RSSReader/Services/FeedRefresher.swift` | 갱신·오프라인 캐시 (ModelActor, 작업마다 새 컨텍스트) |
| `RSSReader/Services/SyncEngine.swift`, `SyncManager.swift` | iCloud Drive 폴더 동기화 |
| `RSSReader/Services/SpeechPlayer.swift` | TTS |
| `RSSReader/Resources/reader.js` | 리더 화면 하이라이트·TTS 문장 표시 (앱 전용 content world) |

### 동기화 형식

DB 쓰기는 모두 메인 컨텍스트 하나에서 한다. SwiftData는 저장할 때 객체의 모든 속성을 쓰기 때문에, 두 컨텍스트가 같은 글을 고치면 나중에 저장한 쪽이 다른 쪽의 변경(별표·읽음 또는 본문)을 지운다. 네트워크, 본문 추출, 파일 입출력만 메인 스레드 밖에서 한다.

동기화 폴더에 기기마다 `devices/<기기 ID>.json` 하나씩, 폰트는 `fonts/`에 둔다. 각 기기는 자기 파일만 쓰고 다른 기기 파일을 읽어 병합한다. 같은 대상이면 `updatedAt`이 최신인 쪽이 이기고, 삭제는 삭제 기록(tombstone)으로 전파한다. 피드는 정규화한 주소, 글은 `피드 주소|guid`, 하이라이트는 UUID로 기기 간 같은 대상을 알아본다. 별표·하이라이트한 글은 글 정보도 함께 보내서, 상대 기기에 없는 예전 글도 만들어진다(본문은 그 기기가 원문에서 다시 받는다).

## 라이선스

[MIT](LICENSE). 함께 쓰는 라이브러리와 참고한 코드의 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있다.
