import Foundation

/// GeekNews 토픽 페이지와 같은 DOM 구조(클래스·ID)를 가진 테스트용 페이지.
/// 글과 댓글은 테스트를 위해 직접 쓴 내용이다.
enum GeekNewsSample {
    static let url = URL(string: "https://news.hada.io/topic?id=1000")!
    static let originalURL = "https://en.wikipedia.org/wiki/RSS"
    static let hnURL = "https://news.ycombinator.com/item?id=1000"

    static let html = """
    <!DOCTYPE html>
    <html lang="KR"><head><meta charset="utf-8" />
    <title>RSS가 여전히 쓸모 있는 이유 | GeekNews</title>
    <script src="/assets/analytics.js"></script>
    </head>
    <body class="topic-detail-page">
    <header><nav>
      <div class=ltd><span class=geeknews><a href="/">GeekNews</a></span> <a href='/new'>최신글</a> <a href='/past'>예전글</a> <a href='/comments'>댓글</a> <a href='/ask'>Ask</a> <a href='/show'>Show</a></div>
      <div class="rtd"><form class="search-cse" action="/search"><input name="q" type="search" placeholder="검색"></form><a href='/login'>로그인</a></div>
    </nav></header>
    <main><article><div class=topic-table>
      <div class=topic>
        <div class=vote><a class=upvote href='javascript:vote(1000, "up");'>▲</a></div>
        <div class='topictitle link'><a href='\(originalURL)' class='bold ud topic-title-link'><h1>RSS가 여전히 쓸모 있는 이유</h1></a> <span class=topicurl>(en.wikipedia.org)</span></div>
        <div class=topicinfo>1P by <a href='/@sample'>샘플봇</a> <time datetime="2026-10-05T15:43:03+09:00">1시간전</time> | <a href='topic?id=1000'>댓글 2개</a></div>
        <div class=topic_contents><div><section id='topic_contents' class='article-content' itemprop='articleBody'>
          <ul>
            <li><strong>RSS</strong>는 사이트가 새 글 목록을 정해진 형식으로 내보내고, 구독자가 그 목록을 주기적으로 받아 보는 방식이다. 알고리즘이 순서를 정하지 않으므로, 구독한 사이트의 새 글이 시간 순서대로 빠짐없이 들어온다.</li>
            <li>서비스 하나에 묶이지 않는다는 점이 가장 큰 장점이다. 구독 목록은 OPML 파일로 내보낼 수 있어서, 리더 앱을 바꿔도 구독을 그대로 옮길 수 있다.</li>
            <li>요약만 보내는 피드도 많아서, 좋은 리더는 원문 페이지에서 본문을 다시 추출해 오프라인으로 저장한다. 이때 메뉴, 광고, 댓글 같은 부분은 걸러 내고 글 본문만 남겨야 읽기 편하다.</li>
          </ul>
          <h2>정리</h2>
          <p>블로그, 뉴스, 논문 알림, 깃허브 릴리스까지 많은 곳이 아직 피드를 제공한다. 읽을 곳을 직접 고르고 싶은 사람에게 RSS는 여전히 가장 단순하고 오래가는 방법이다.</p>
        </section></div></div>
      </div>
    </div>
    <div class="related-topics"><h2>함께 보면 좋은 글</h2><ul>
      <li><a href="/topic?id=999" class="related-topic-link">피드 리더 비교</a></li>
      <li><a href="/topic?id=998" class="related-topic-link">OPML 파일 형식</a></li>
    </ul></div>
    <h2 id="discussion" class="visually-hidden">댓글과 토론</h2>
    <div class=comment_form><form class="write_comment" action="/comments" method="POST"><textarea name="contents" placeholder="댓글"></textarea><input type="submit" value="댓글 달기"></form></div>
    <div id='comment_thread' class='comment_thread descendant'>
      <div class=comment_row id=cid1 style=--depth:0>
        <div class=commentinfo><a href="/@sample">샘플봇</a> <a href='/topic?id=1000#cid1'><time class="js-relative-time" datetime="2026-10-05T15:43:04+09:00">1시간전</time></a></div>
        <div class=commentTD><span id='contents1' class='comment_contents'><h6><a href="\(hnURL)">Hacker News 의견들</a></h6>
          <ul><li class="hn">구독 목록을 파일로 옮길 수 있다는 점 때문에 계속 RSS를 쓰고 있음</li></ul>
          <script>track()</script>
        </span></div>
      </div>
      <div class=comment_row id=cid2 style=--depth:1>
        <div class=commentinfo><a href="/@reader">읽는사람</a> <a href='/topic?id=1000#cid2'><time class="js-relative-time" datetime="2026-10-05T16:10:00+09:00">30분전</time></a></div>
        <div class=commentTD><span id='contents2' class='comment_contents'><p>저도 같은 이유로 씁니다.</p></span></div>
      </div>
    </div>
    </article></main>
    </body></html>
    """
}
