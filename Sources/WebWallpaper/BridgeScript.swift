/// 页面开始解析前注入的兼容脚本，提供 Wallpaper Engine 网页壁纸用到的全局接口。
///
/// 接口约定来自 WE 官方的网页壁纸文档（见 REFERENCES.md）。原生一侧通过 window.__wallpaperApply
/// 调用页面设置的 wallpaperPropertyListener；页面通过 webkit.messageHandlers.wallpaper 把控制台输出
/// 和事件报回原生，写进诊断日志。
enum BridgeScript {
    static let handlerName = "wallpaper"

    /// - Parameter frameRate: 页面动画的帧率上限，和通过 applyGeneralProperties 告诉页面的 fps 一致
    static func source(frameRate: Int) -> String {
        #"""
    (() => {
      const post = (type, payload) => {
        try { window.webkit.messageHandlers.wallpaper.postMessage({ type, payload }); } catch (_) {}
      };
      const describe = (value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return value.stack || String(value);
        try { return JSON.stringify(value); } catch (_) { return String(value); }
      };

      // 控制台输出与脚本错误转进原生日志，排查"某个壁纸为什么不动"时靠它
      for (const level of ['log', 'info', 'warn', 'error']) {
        const original = console[level].bind(console);
        console[level] = (...args) => {
          original(...args);
          post('console', level + ': ' + args.map(describe).join(' '));
        };
      }
      window.addEventListener('error', (event) => {
        post('console', 'error: ' + event.message + ' @ ' + (event.filename || '?') + ':' + (event.lineno || 0));
      });
      window.addEventListener('unhandledrejection', (event) => {
        post('console', 'unhandledrejection: ' + describe(event.reason));
      });

      // 音频：页面注册回调，原生一侧每秒约 30 次送来 128 个值（左右声道各 64 个频段）
      const audioListeners = [];
      window.wallpaperRegisterAudioListener = (callback) => {
        if (typeof callback !== 'function') return;
        audioListeners.push(callback);
        post('audioListener');
      };
      window.__wallpaperDispatchAudio = (samples) => {
        for (const callback of audioListeners) {
          try { callback(samples); } catch (error) { post('console', 'error: audio listener ' + describe(error)); }
        }
      };

      // 媒体集成和目录类属性在 macOS 上暂时没有数据来源，只接受注册，避免页面调用时报错
      for (const name of [
        'wallpaperRegisterMediaStatusListener',
        'wallpaperRegisterMediaPropertiesListener',
        'wallpaperRegisterMediaThumbnailListener',
        'wallpaperRegisterMediaPlaybackListener',
        'wallpaperRegisterMediaTimelineListener',
      ]) {
        window[name] = () => {};
      }
      window.wallpaperRequestRandomFileForProperty = () => {};

      // 帧率上限与冻结。WE 按自己的 FPS 设置限制网页壁纸的渲染帧率，这里在页面脚本运行之前包一层
      // requestAnimationFrame 做同样的事；暂停时干脆不再派发回调，这样不理会 setPaused 的页面也会停下来。
      const nativeRequest = window.requestAnimationFrame.bind(window);
      const pendingFrames = new Map();
      let nextFrameId = 1;
      let frameInterval = 1000 / \#(frameRate);
      let lastFrameTime = 0;
      let frameScheduled = false;
      let frozen = false;
      let deliveredFrames = 0;
      const scheduleFrame = () => {
        if (frameScheduled || frozen || pendingFrames.size === 0) return;
        frameScheduled = true;
        nativeRequest(runFrame);
      };
      const runFrame = (now) => {
        frameScheduled = false;
        if (frozen) return;
        const elapsed = now - lastFrameTime;
        // 留 1 毫秒余量，避免显示器刷新时间的抖动让 30 帧掉成 20 帧
        if (elapsed < frameInterval - 1) { scheduleFrame(); return; }
        // 超出间隔的零头算进下一帧，保持平均帧率；在容差内提前到达（零头为负）或落后太多时从现在重新计时。
        // 不能用 elapsed % frameInterval：提前到达时它等于 elapsed 本身，会让下一帧立刻放行，帧率翻倍
        const carry = elapsed - frameInterval;
        lastFrameTime = carry > 0 && carry < frameInterval ? now - carry : now;
        const callbacks = Array.from(pendingFrames.values());
        pendingFrames.clear();
        deliveredFrames += 1;
        for (const callback of callbacks) {
          try { callback(now); } catch (error) { post('console', 'error: requestAnimationFrame ' + describe(error)); }
        }
      };
      window.requestAnimationFrame = (callback) => {
        const id = nextFrameId++;
        pendingFrames.set(id, callback);
        scheduleFrame();
        return id;
      };
      window.cancelAnimationFrame = (id) => { pendingFrames.delete(id); };
      window.__wallpaperSetFrameRate = (fps) => { frameInterval = 1000 / Math.max(1, fps); };
      window.__wallpaperDeliveredFrames = () => deliveredFrames;

      // 壁纸设置里的音量：乘在页面自己设的音量上（作者把背景音乐调到 0.2，设置里是 50% 就放 0.1）。
      // 页面读 volume 时拿到的仍是它自己设的值。已有的 <audio> / <video> 马上调，之后开始播放的在 play() 时调
      let pageVolume = 1;
      const authorVolumes = new WeakMap();
      const volumeProperty = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
      const applyVolume = (media) => {
        if (!volumeProperty) return;
        if (!authorVolumes.has(media)) authorVolumes.set(media, volumeProperty.get.call(media));
        try { volumeProperty.set.call(media, authorVolumes.get(media) * pageVolume); } catch (error) {}
      };
      if (volumeProperty && volumeProperty.get && volumeProperty.set) {
        Object.defineProperty(HTMLMediaElement.prototype, 'volume', {
          configurable: true,
          enumerable: volumeProperty.enumerable,
          get() { return authorVolumes.has(this) ? authorVolumes.get(this) : volumeProperty.get.call(this); },
          set(value) {
            // 和原生一样校验（不是有限数、超出 0–1 都抛错），记下作者要的值，乘上壁纸设置的音量只设一次：
            // 设两次会多发一个 volumechange，页面在它里面再设音量的话就来回触发停不下来
            const volume = Number(value);
            if (!Number.isFinite(volume)) throw new TypeError('The provided double value is non-finite.');
            if (volume < 0 || volume > 1) {
              throw new DOMException(`The volume provided (${volume}) is outside the range [0, 1].`, 'IndexSizeError');
            }
            authorVolumes.set(this, volume);
            volumeProperty.set.call(this, volume * pageVolume);
          },
        });
      }
      const originalPlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function (...args) {
        applyVolume(this);
        return originalPlay.apply(this, args);
      };
      window.__wallpaperSetVolume = (volume) => {
        pageVolume = Math.min(1, Math.max(0, Number(volume) || 0));
        for (const media of document.querySelectorAll('audio, video')) applyVolume(media);
      };
      window.__wallpaperSetFrozen = (value) => {
        frozen = value;
        if (!frozen) scheduleFrame();
      };

      // 原生一侧调用页面的 wallpaperPropertyListener；页面可能在任何时候才设置它，所以每次现取
      window.__wallpaperApply = (method, ...args) => {
        const listener = window.wallpaperPropertyListener;
        if (!listener || typeof listener[method] !== 'function') return;
        try { listener[method](...args); } catch (error) { post('console', 'error: ' + method + ' ' + describe(error)); }
      };
    })();
    """#
    }
}
