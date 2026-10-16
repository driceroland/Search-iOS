import Foundation

// Reading mode: the article, and nothing that was arranged around it. The
// Mac's own script, with a phone's margins and a dark version.
//
// The hard part is deciding what the article is: here, the smallest part of
// the page that holds most of its prose (the Mac's rule, punishing every link,
// chose Wikipedia's donation banner over a well-linked article on a phone).

enum Reader {
    static let script = """
    (function () {
      // How much reading an element holds: the letters of its paragraphs,
      // counted from textContent so a section a phone layout has folded
      // shut still counts.
      function letters(el) {
        var total = 0, paragraphs = el.querySelectorAll('p, pre, blockquote');
        for (var i = 0; i < paragraphs.length; i++) {
          var n = (paragraphs[i].textContent || '').trim().length;
          if (n >= 40) total += n;
        }
        return total;
      }

      // The smallest piece of the page that still holds most of its prose:
      // go down from the body while one child keeps three quarters of it.
      // A banner or a rail beside the article is too small to be chosen,
      // and an article full of links isn't punished for them.
      function best() {
        var all = letters(document.body);
        if (all < 400) return null;
        var here = document.body;
        for (;;) {
          var next = null;
          for (var c = 0; c < here.children.length; c++) {
            var child = here.children[c];
            if (letters(child) >= all * 0.75) { next = child; break; }
          }
          if (!next) return here;
          here = next;
        }
      }

      var article = best();
      if (!article) return 'none';

      // Every picture is resolved while the real page is still standing.
      //
      // currentSrc is what the browser actually chose and loaded, after srcset,
      // sizes and <picture> have had their say. Reading it here and writing it
      // back as a plain src is the only way to be sure the reader shows the
      // same image the page did — copying the markup alone gets you a lazy
      // placeholder, or nothing at all.
      var late = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy',
                  'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo'];
      var pictures = article.querySelectorAll('img');
      for (var i = 0; i < pictures.length; i++) {
        var picture = pictures[i];
        picture.setAttribute('loading', 'eager');
        var real = picture.currentSrc || picture.getAttribute('src') || '';
        // A one-pixel placeholder counts as nothing.
        if (!real || real.indexOf('data:image') === 0 || picture.naturalWidth <= 2) {
          for (var k = 0; k < late.length; k++) {
            var kept = picture.getAttribute(late[k]);
            if (kept) { real = kept; break; }
          }
        }
        if (real) picture.setAttribute('src', real);
        var lateSet = picture.getAttribute('data-srcset');
        if (lateSet && !picture.getAttribute('srcset')) {
          picture.setAttribute('srcset', lateSet);
        }
      }

      var heading = document.querySelector('h1');
      var title = (heading && heading.innerText.trim()) || document.title;

      var sheet = document.createElement('style');
      sheet.textContent = [
        'html,body{background:#fff !important;margin:0 !important;padding:0 !important}',
        '#office-reader{max-width:38em;margin:0 auto;padding:40px 22px 140px;',
        'font:400 19px/1.66 ui-serif,Georgia,"Times New Roman",serif;color:#171717;',
        '-webkit-text-size-adjust:100%}',
        '#office-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;',
        'margin:0 0 8px;letter-spacing:-0.01em}',
        '#office-reader .office-from{font:400 12px/1 -apple-system,sans-serif;color:#a3a3a3;',
        'margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}',
        '#office-reader p{margin:0 0 1.35em}',
        '#office-reader section,#office-reader [hidden]{display:block !important}',
        '#office-reader img,#office-reader video,#office-reader iframe{max-width:100%;',
        'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
        '#office-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
        '#office-reader figure{margin:1.8em 0}',
        '#office-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;',
        'color:#a3a3a3;margin-top:.6em}',
        '#office-reader a{color:#171717;text-underline-offset:3px}',
        '#office-reader h2,#office-reader h3{font:600 20px/1.3 -apple-system,sans-serif;',
        'margin:2em 0 .6em}',
        '#office-reader pre,#office-reader code{font-family:ui-monospace,monospace;font-size:14px}',
        '#office-reader pre{background:#f5f5f5;padding:14px;border-radius:8px;overflow:auto}',
        '#office-reader blockquote{margin:1.6em 0;padding-left:1.2em;',
        'border-left:2px solid #e8e8e8;color:#555}',
        // The same page at night: the app's own dark greys, not the page's.
        '@media (prefers-color-scheme: dark){',
        'html,body{background:#1c1c1c !important}',
        '#office-reader,#office-reader a{color:#ededed}',
        '#office-reader .office-from,#office-reader figcaption{color:#8f8f8f}',
        '#office-reader pre{background:#2a2a2a}',
        '#office-reader blockquote{border-left-color:#333;color:#b5b5b5}}'
      ].join('');

      var wrap = document.createElement('div');
      wrap.id = 'office-reader';
      wrap.innerHTML = article.innerHTML;

      // What was arranged around the words rather than being part of them.
      // Not header: an article's opening image lives there as often as not.
      var clutter = wrap.querySelectorAll(
        'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
        '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
      );
      for (var c = 0; c < clutter.length; c++) clutter[c].remove();

      // Embedded video is part of the article; every other frame is not.
      var players = /youtube|youtu\\.be|vimeo|dailymotion|loom\\.com|streamable|wistia|ted\\.com/i;
      var frames = wrap.querySelectorAll('iframe');
      for (var f = 0; f < frames.length; f++) {
        var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
        if (players.test(where)) {
          frames[f].setAttribute('src', where);
          frames[f].removeAttribute('height');
          frames[f].removeAttribute('width');
        } else {
          frames[f].remove();
        }
      }

      // A picture with nothing behind it is a broken icon, which is worse than
      // no picture at all.
      var kept = wrap.querySelectorAll('img');
      for (var g = 0; g < kept.length; g++) {
        var src = kept[g].getAttribute('src') || '';
        if (!src || src.indexOf('data:image') === 0) kept[g].remove();
      }

      var top = document.createElement('h1');
      top.textContent = title;
      var from = document.createElement('p');
      from.className = 'office-from';
      from.textContent = location.host.replace(/^www\\./, '');

      document.body.innerHTML = '';
      document.head.appendChild(sheet);
      wrap.insertBefore(from, wrap.firstChild);
      wrap.insertBefore(top, wrap.firstChild);
      document.body.appendChild(wrap);
      window.scrollTo(0, 0);
      return 'read';
    })();
    """
}
