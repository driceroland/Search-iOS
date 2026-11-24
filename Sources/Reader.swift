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
        // Drawn small on the page (an icon, a logo): marked now, while its
        // size can still be read, and left out of the copy.
        var drawn = picture.getBoundingClientRect().width;
        if ((drawn > 0 && drawn <= 64) || (picture.naturalWidth > 2 && picture.naturalWidth <= 64)) {
          picture.setAttribute('data-office-small', '1');
        }
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
        '#office-reader blockquote{border-left-color:#333;color:#b5b5b5}',
        // What the page painted itself (an infobox, a table, a note): its
        // light grounds and dark inks give way to the reader's, or it reads
        // as light text on white.
        '#office-reader table,#office-reader thead,#office-reader tbody,#office-reader tr,',
        '#office-reader th,#office-reader td,#office-reader div,#office-reader span,',
        '#office-reader section,#office-reader aside,#office-reader caption,#office-reader li',
        '{background-color:transparent !important;color:inherit !important;border-color:#3a3a3a !important}',
        '#office-reader th{background-color:#262626 !important}}'
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

      // What the site hung around the words inside the article itself:
      // share and follow rows, newsletter boxes, related links, ads. Found
      // by their names, and only when they hold little prose, so an article
      // whose wrapper happens to be called "promo" is never lost.
      var aside = /share|social|follow|newsletter|subscribe|signup|promo|related|recirc|advert|sponsor|outbrain|taboola|comment|toolbar|breadcrumb|sticky|header-bar|site-header|masthead|tags?-list|author-bio|google-news|preferred-source/i;
      var named = wrap.querySelectorAll('[class],[id],[data-testid]');
      for (var n = named.length - 1; n >= 0; n--) {
        var el = named[n];
        if (!el.isConnected) continue;
        var name = (el.getAttribute('class') || '') + ' ' + (el.id || '') + ' ' + (el.getAttribute('data-testid') || '');
        if (aside.test(name) && letters(el) < 200) el.remove();
      }
      // What the page itself kept out of sight, by hand, with little prose:
      // with its look gone (below), it would suddenly show.
      var tucked = wrap.querySelectorAll('[style]');
      for (var u = tucked.length - 1; u >= 0; u--) {
        var how = (tucked[u].getAttribute('style') || '').replace(/\\s/g, '');
        if (/display:none|visibility:hidden/i.test(how) && letters(tucked[u]) < 200) tucked[u].remove();
      }

      // "Skip to content", and links that only send you somewhere about the
      // site (a news app's source settings, a share sheet).
      var links = wrap.querySelectorAll('a');
      for (var q = 0; q < links.length; q++) {
        var said = (links[q].textContent || '').trim();
        var to = links[q].getAttribute('href') || '';
        if (/^skip to/i.test(said) || /google\\.com\\/(preferences|search\\?.*source)|news\\.google|share|intent\\/tweet|facebook\\.com\\/sharer/i.test(to)) {
          links[q].remove();
        }
      }
      // Pictures too small to be the article's: icons and logos.
      var small = wrap.querySelectorAll('img[data-office-small]');
      for (var z = 0; z < small.length; z++) small[z].remove();

      // Links dressed as buttons (Share, Add us on Google) and lone icons.
      var dressed = wrap.querySelectorAll('[role="button"],svg');
      for (var b = 0; b < dressed.length; b++) dressed[b].remove();

      // The article's own title: ours is on top already.
      var own = wrap.querySelectorAll('h1');
      for (var h = 0; h < own.length; h++) {
        if ((own[h].textContent || '').trim() === title.trim()) own[h].remove();
      }

      // The site's own look goes: kept, it went on styling what was copied
      // (bars stayed bars, and parts waiting to fade in as you scrolled stayed
      // invisible, a blank where the rest of the article was).
      var looks = wrap.querySelectorAll('[class],[style],[id]');
      for (var l = 0; l < looks.length; l++) {
        looks[l].removeAttribute('class');
        looks[l].removeAttribute('style');
        looks[l].removeAttribute('id');
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
      var theirs = document.querySelectorAll('link[rel~="stylesheet"],style');
      for (var t = 0; t < theirs.length; t++) theirs[t].remove();
      document.body.removeAttribute('class');
      document.body.removeAttribute('style');
      document.documentElement.removeAttribute('class');
      document.documentElement.removeAttribute('style');
      document.head.appendChild(sheet);
      wrap.insertBefore(from, wrap.firstChild);
      wrap.insertBefore(top, wrap.firstChild);
      document.body.appendChild(wrap);
      window.scrollTo(0, 0);
      return 'read';
    })();
    """
}
