/**
 * Addon_Lyrics_YoutubeCaption.js
 * YouTube 공식 뮤직비디오 자막(caption)을 가사 소스로 사용하는 ivLyrics 애드온
 *
 * 동작 방식:
 *   Spotify 트랙 정보 → VPS 서버(FastAPI + yt-dlp) → YouTube 검색 및 자막 추출
 *   → LRC 포맷 반환 → ivLyrics에 synced/unsynced 가사로 표시
 *
 * 설치:
 *   이 파일을 ivLyrics 폴더에 복사 후 manifest.json의 subfiles_extension에 추가
 *   manifest.json > subfiles_extension 배열:
 *     "Addon_Lyrics_Lrclib.js" 다음 줄에 "Addon_Lyrics_YoutubeCaption.js" 추가
 *
 * 서버 설정:
 *   server.py (동봉) 를 VPS 또는 로컬에서 실행 후
 *   ivLyrics 설정 > 가사 소스 탭 > YouTube Caption > 서버 URL 입력
 *
 * @addon-type  lyrics
 * @id          youtube-caption
 * @version     1.0.0
 * @author      ivLis STUDIO
 */

(() => {
    'use strict';

    // ============================================
    // Addon Metadata
    // ============================================

    const ADDON_ID      = 'youtube-caption';
    const ADDON_VERSION = '1.0.0';
    const GITHUB_VERSION_URL = 'https://raw.githubusercontent.com/ivLis-Studio/ivLyrics/main/ytcaption-server/version.json';

    const ADDON_INFO = {
        id: ADDON_ID,
        name: 'YouTube Caption',
        author: 'ivLis STUDIO',
        version: '1.0.0',
        description: {
            en: 'Fetches lyrics from YouTube official MV captions via an external yt-dlp server. Manual captions are preferred; auto-captions are used as fallback.',
            ko: 'yt-dlp 외부 서버를 통해 YouTube 공식 뮤직비디오 자막에서 가사를 가져옵니다. 수동 자막을 우선 사용하며, 없을 경우 자동 생성 자막을 사용합니다.',
        },
        supports: {
            karaoke:  false,  // yt-dlp 자막은 줄 단위 타이밍만 제공
            synced:   true,   // LRC 형식 → startTime(ms) + text
            unsynced: true,   // 텍스트 전용 fallback
        },
        // ivLyrics 커뮤니티 sync-data로 karaoke 자동 변환 활성화
        useIvLyricsSync: true,
        // YouTube 재생 버튼 아이콘
        icon: 'M10 15l5.19-3L10 9v6m11.56-7.83c.13.47.22 1.1.28 1.9.07.8.1 1.49.1 2.09L22 12c0 2.19-.16 3.8-.44 4.83-.25.9-.83 1.48-1.73 1.73-.47.13-1.33.22-2.65.28-1.3.07-2.49.1-3.59.1L12 19c-4.19 0-6.8-.16-7.83-.44-.9-.25-1.48-.83-1.73-1.73-.13-.47-.22-1.1-.28-1.9-.07-.8-.1-1.49-.1-2.09L2 12c0-2.19.16-3.8.44-4.83.25-.9.83-1.48 1.73-1.73.47-.13 1.33-.22 2.65-.28 1.3-.07 2.49-.1 3.59-.1L12 5c4.19 0 6.8.16 7.83.44.9.25 1.48.83 1.73 1.73z',
    };

    // ============================================
    // Setting Keys
    // LyricsAddonManager.getAddonSetting/setAddonSetting 의 키 규칙:
    //   'ivLyrics:lyrics:addon:{addonId}:{key}'
    // ============================================

    const SETTING = {
        SERVER_URL:  'server-url',   // 서버 주소 (기본: http://localhost:8080)
        API_SECRET:  'api-secret',   // Bearer 토큰 (선택)
        TIMEOUT_SEC: 'timeout-sec',  // 요청 타임아웃(초)
    };

    const DEFAULT_SERVER_URL  = 'http://localhost:8080';
    const DEFAULT_TIMEOUT_SEC = 30;

    // ============================================
    // Helpers — LyricsAddonManager.getAddonSetting 래핑
    // ============================================

    function getSetting(key, defaultValue) {
        return window.LyricsAddonManager?.getAddonSetting(ADDON_ID, key, defaultValue) ?? defaultValue;
    }

    function setSetting(key, value) {
        window.LyricsAddonManager?.setAddonSetting(ADDON_ID, key, value);
    }

    function getServerUrl() {
        const v = getSetting(SETTING.SERVER_URL, DEFAULT_SERVER_URL);
        return (v || DEFAULT_SERVER_URL).replace(/\/$/, '');
    }

    function getApiSecret() {
        return getSetting(SETTING.API_SECRET, '') || '';
    }

    function getTimeoutMs() {
        const v = parseInt(getSetting(SETTING.TIMEOUT_SEC, DEFAULT_TIMEOUT_SEC), 10);
        return (isNaN(v) || v < 5 ? DEFAULT_TIMEOUT_SEC : v) * 1000;
    }

    function buildHeaders() {
        const headers = {};
        const secret = getApiSecret().trim();
        if (secret) headers['Authorization'] = `Bearer ${secret}`;
        return headers;
    }


    // ============================================
    // LRC Parser
    // [MM:SS.xx] 또는 [MM:SS,xx] → { synced, unsynced }
    // Addon_Lyrics_Lrclib.js 와 동일한 반환 포맷
    // ============================================

    function parseLRC(lrc) {
        if (!lrc || typeof lrc !== 'string') return { synced: null, unsynced: [] };

        const synced   = [];
        const unsynced = [];

        for (const line of lrc.split('\n')) {
            const m = line.match(/\[(\d+):(\d+)(?:[.,](\d+))?\](.*)/);
            if (m) {
                const ms = Math.floor(
                    (parseInt(m[1], 10) * 60 + parseInt(m[2], 10) + parseFloat('0.' + (m[3] || '0'))) * 1000
                );
                const text = m[4].trim();
                synced.push({ startTime: ms, text });
                unsynced.push({ text });
            } else if (line.trim() && !line.startsWith('[')) {
                unsynced.push({ text: line.trim() });
            }
        }

        return {
            synced:   synced.length   > 0 ? synced   : null,
            unsynced: unsynced.length > 0 ? unsynced : null,
        };
    }

    // ============================================
    // Settings UI (React Component)
    // getSettingsUI() → ivLyrics 설정 패널에 자동 렌더링
    // ============================================

    function getSettingsUI() {
        const React = Spicetify.React;
        const { useState, useEffect } = React;

        return function YoutubeCaptionSettings() {
            const [serverUrl,  setServerUrl]  = useState(() => getSetting(SETTING.SERVER_URL,  DEFAULT_SERVER_URL));
            const [apiSecret,  setApiSecret]  = useState(() => getSetting(SETTING.API_SECRET,  ''));
            const [timeoutSec, setTimeoutSec] = useState(() => getSetting(SETTING.TIMEOUT_SEC, DEFAULT_TIMEOUT_SEC));
            const [testStatus, setTestStatus] = useState(null); // null | 'testing' | 'ok' | 'fail'

            const save = (key, value) => setSetting(key, value);

            const testConnection = async () => {
                setTestStatus('testing');
                const url = (serverUrl || DEFAULT_SERVER_URL).replace(/\/$/, '');
                const headers = {};
                const secret = (apiSecret || '').trim();
                if (secret) headers['Authorization'] = `Bearer ${secret}`;
                try {
                    const res = await fetch(`${url}/health`, {
                        headers,
                        signal: AbortSignal.timeout(5000),
                    });
                    setTestStatus(res.ok ? 'ok' : 'fail');
                } catch {
                    setTestStatus('fail');
                }
            };

            const STATUS_COLOR = { ok: '#1db954', fail: '#e91429', testing: '#888' };
            const STATUS_LABEL = {
                ok:      '✓ 연결 성공',
                fail:    '✗ 연결 실패',
                testing: '연결 테스트 중...',
            };

            return React.createElement('div', { className: 'ai-addon-settings youtube-caption-settings' },

                // 설명 박스
                React.createElement('div', { className: 'ai-addon-info-box', style: { marginBottom: 16 } },
                    React.createElement('p', { style: { fontWeight: 'bold', marginBottom: 6 } },
                        'YouTube Caption Provider'),
                    React.createElement('p', { style: { opacity: 0.8, fontSize: 13, lineHeight: 1.6 } },
                        'yt-dlp 외부 서버를 통해 YouTube 공식 MV 자막을 가사로 표시합니다. ',
                        '수동 등록 자막을 우선하며, 없을 경우 자동 생성 자막을 사용합니다.'
                    )
                ),

                // 서버 URL
                React.createElement('div', { className: 'ai-addon-setting' },
                    React.createElement('label', { className: 'ai-addon-setting-label' }, '서버 URL'),
                    React.createElement('input', {
                        type: 'text',
                        className: 'ai-addon-setting-input',
                        placeholder: DEFAULT_SERVER_URL,
                        value: serverUrl,
                        onChange: (e) => {
                            setServerUrl(e.target.value);
                            save(SETTING.SERVER_URL, e.target.value);
                            setTestStatus(null);
                        },
                    }),
                    React.createElement('p', { className: 'ai-addon-setting-description' },
                        'VPS 또는 로컬에서 실행 중인 yt-dlp 서버 주소.',
                        React.createElement('br'),
                        '예: http://123.456.789.0:8080 또는 https://captions.your-domain.com'
                    )
                ),

                // API 키 (선택)
                React.createElement('div', { className: 'ai-addon-setting' },
                    React.createElement('label', { className: 'ai-addon-setting-label' }, 'API 키 (선택)'),
                    React.createElement('input', {
                        type: 'password',
                        className: 'ai-addon-setting-input',
                        placeholder: '서버에 API_SECRET이 설정된 경우에만 입력',
                        value: apiSecret,
                        onChange: (e) => {
                            setApiSecret(e.target.value);
                            save(SETTING.API_SECRET, e.target.value);
                            setTestStatus(null);
                        },
                    })
                ),

                // 타임아웃 슬라이더
                React.createElement('div', { className: 'ai-addon-setting' },
                    React.createElement('label', { className: 'ai-addon-setting-label' },
                        `요청 타임아웃: ${timeoutSec}초`),
                    React.createElement('input', {
                        type: 'range',
                        min: '10',
                        max: '120',
                        step: '5',
                        value: String(timeoutSec),
                        onChange: (e) => {
                            const v = Number(e.target.value);
                            setTimeoutSec(v);
                            save(SETTING.TIMEOUT_SEC, v);
                        },
                    }),
                    React.createElement('p', { className: 'ai-addon-setting-description' },
                        'yt-dlp 처리 시간을 고려해 30초 이상을 권장합니다.'
                    )
                ),

                // 연결 테스트 버튼
                React.createElement('div', {
                    className: 'ai-addon-setting',
                    style: { display: 'flex', alignItems: 'center', gap: 12, marginTop: 8 },
                },
                    React.createElement('button', {
                        className: 'ai-addon-setting-button',
                        onClick: testConnection,
                        disabled: testStatus === 'testing',
                    }, '연결 테스트'),
                    testStatus && React.createElement('span', {
                        style: { color: STATUS_COLOR[testStatus], fontSize: 13, fontWeight: 'bold' },
                    }, STATUS_LABEL[testStatus])
                ),

                // 버전 + 업데이트 섹션
                React.createElement(VersionSection, { serverUrl, apiSecret })
            );
        };
    }

    // 버전 정보 + 업데이트 알림 컴포넌트
    function VersionSection({ serverUrl, apiSecret }) {
        const React = Spicetify.React;
        const { useState, useEffect } = React;

        const [serverInfo,    setServerInfo]    = useState(null);
        const [addonUpdate,   setAddonUpdate]   = useState(null);
        const [updateStatus,  setUpdateStatus]  = useState(null); // null | 'updating' | 'done' | 'fail'
        const [checking,      setChecking]      = useState(false);

        const checkVersions = async () => {
            setChecking(true);
            try {
                // 서버 버전 확인
                const url = (serverUrl || DEFAULT_SERVER_URL).replace(/\/$/, '');
                const headers = {};
                const secret = (apiSecret || '').trim();
                if (secret) headers['Authorization'] = `Bearer ${secret}`;

                const res = await fetch(`${url}/health`, {
                    headers,
                    signal: AbortSignal.timeout(5000),
                });
                if (res.ok) {
                    const data = await res.json();
                    setServerInfo(data);
                }

                // 애드온 버전 확인 (GitHub version.json)
                const vRes = await fetch(GITHUB_VERSION_URL + '?ts=' + Date.now(), {
                    signal: AbortSignal.timeout(5000),
                });
                if (vRes.ok) {
                    const vData = await vRes.json();
                    const latestAddon = vData.addon || ADDON_VERSION;
                    if (latestAddon !== ADDON_VERSION) {
                        setAddonUpdate(latestAddon);
                    }
                }
            } catch (e) {
                // ignore
            } finally {
                setChecking(false);
            }
        };

        const triggerServerUpdate = async () => {
            setUpdateStatus('updating');
            try {
                const url = (serverUrl || DEFAULT_SERVER_URL).replace(/\/$/, '');
                const headers = { 'Content-Type': 'application/json' };
                const secret = (apiSecret || '').trim();
                if (secret) headers['Authorization'] = `Bearer ${secret}`;

                const res = await fetch(`${url}/update`, {
                    method: 'POST',
                    headers,
                    signal: AbortSignal.timeout(10000),
                });
                const data = await res.json();
                setUpdateStatus(data.status === 'up-to-date' ? 'done' : 'updating');
                if (data.status === 'updating') {
                    // 10초 후 다시 확인
                    setTimeout(() => {
                        checkVersions();
                        setUpdateStatus('done');
                    }, 10000);
                }
            } catch {
                setUpdateStatus('fail');
            }
        };

        // 마운트 시 버전 확인
        useEffect(() => { checkVersions(); }, []);

        const UPDATE_COLOR = { updating: '#fbbf24', done: '#1db954', fail: '#e91429' };
        const UPDATE_LABEL = {
            updating: '업데이트 중...',
            done:     '✓ 업데이트 완료',
            fail:     '✗ 업데이트 실패',
        };

        return React.createElement('div', {
            className: 'ai-addon-setting',
            style: { marginTop: 16, borderTop: '1px solid rgba(255,255,255,0.1)', paddingTop: 16 }
        },
            // 버전 정보
            React.createElement('div', { style: { display: 'flex', gap: 16, marginBottom: 10, fontSize: 12, opacity: 0.7 } },
                React.createElement('span', null, `애드온 v${ADDON_VERSION}`),
                serverInfo && React.createElement('span', null, `서버 v${serverInfo.version}`),
                checking && React.createElement('span', null, '버전 확인 중...')
            ),

            // 서버 업데이트 알림
            serverInfo?.hasUpdate && React.createElement('div', {
                style: { display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8,
                    padding: '8px 12px', borderRadius: 8,
                    background: 'rgba(251,191,36,0.1)', border: '1px solid rgba(251,191,36,0.3)' }
            },
                React.createElement('span', { style: { fontSize: 13, color: '#fbbf24' } },
                    `🔄 서버 업데이트: v${serverInfo.version} → v${serverInfo.latestVersion}`),
                React.createElement('button', {
                    className: 'ai-addon-setting-button',
                    style: { marginLeft: 'auto', fontSize: 11 },
                    onClick: triggerServerUpdate,
                    disabled: updateStatus === 'updating',
                }, updateStatus ? UPDATE_LABEL[updateStatus] : '지금 업데이트'),
                updateStatus && React.createElement('span', {
                    style: { color: UPDATE_COLOR[updateStatus], fontSize: 12, fontWeight: 'bold' }
                }, UPDATE_LABEL[updateStatus])
            ),

            // 애드온 업데이트 알림
            addonUpdate && React.createElement('div', {
                style: { padding: '8px 12px', borderRadius: 8, fontSize: 13,
                    background: 'rgba(251,191,36,0.1)', border: '1px solid rgba(251,191,36,0.3)',
                    color: '#fbbf24' }
            },
                `🔄 애드온 업데이트: v${ADDON_VERSION} → v${addonUpdate}`,
                React.createElement('br'),
                React.createElement('span', { style: { fontSize: 11, opacity: 0.8 } },
                    'ivLyrics 마켓플레이스 또는 install 스크립트로 업데이트하세요.')
            ),

            // 버전 재확인 버튼
            React.createElement('button', {
                className: 'ai-addon-setting-button',
                onClick: checkVersions,
                disabled: checking,
                style: { marginTop: 4 }
            }, checking ? '확인 중...' : '버전 확인')
        );
    }


    // ============================================
    // getLyrics — 핵심 메서드
    // LyricsAddonManager 가 호출하는 표준 인터페이스
    // ============================================

    /**
     * @param {Object} info  { uri, title, artist, album, duration }
     * @returns {Promise<LyricsResult>}
     *
     * LyricsResult:
     * {
     *   uri:       string,
     *   provider:  string,
     *   karaoke:   null,
     *   synced:    Array<{startTime:number, text:string}> | null,
     *   unsynced:  Array<{text:string}> | null,
     *   copyright: null,
     *   error:     string | null,
     * }
     */
    async function getLyrics(info) {
        const result = {
            uri:       info.uri,
            provider:  ADDON_ID,
            karaoke:   null,
            synced:    null,
            unsynced:  null,
            copyright: null,
            error:     null,
        };

        // 서버 URL 확인
        const serverUrl = getServerUrl();
        if (!serverUrl) {
            result.error = 'YouTube Caption 서버 URL이 설정되지 않았습니다. 설정에서 서버 URL을 입력해주세요.';
            window.__ivLyricsDebugLog?.(`[${ADDON_ID}] Error: server URL not configured`);
            return result;
        }

        const title  = (info.title  || '').trim();
        const artist = (info.artist || '').trim();
        if (!title || !artist) {
            result.error = '트랙 정보(제목 또는 아티스트)가 없습니다.';
            return result;
        }

        window.__ivLyricsDebugLog?.(
            `[${ADDON_ID}] Fetching: "${title}" by "${artist}" → ${serverUrl}`
        );

        // 서버 요청
        const params = new URLSearchParams({ title, artist, format: 'lrc' });
        const fetchUrl = `${serverUrl}/captions?${params}`;
        const timeout  = getTimeoutMs();

        let response;
        try {
            response = await fetch(fetchUrl, {
                headers: buildHeaders(),
                signal:  AbortSignal.timeout(timeout),
            });
        } catch (e) {
            const isTimeout = e.name === 'TimeoutError' || e.name === 'AbortError';
            result.error = isTimeout
                ? `서버 요청 타임아웃 (${timeout / 1000}초). yt-dlp 처리 중일 수 있습니다.`
                : `서버 연결 실패: ${e.message}`;
            window.__ivLyricsDebugLog?.(`[${ADDON_ID}] Network error: ${result.error}`);
            return result;
        }

        if (!response.ok) {
            let detail = `HTTP ${response.status}`;
            try {
                const body = await response.json();
                if (body?.detail) detail = body.detail;
            } catch { /* ignore */ }
            result.error = detail;
            window.__ivLyricsDebugLog?.(`[${ADDON_ID}] Server error: ${detail}`);
            return result;
        }

        let data;
        try {
            data = await response.json();
        } catch (e) {
            result.error = '서버 응답 파싱 실패';
            return result;
        }

        if (!data?.lrc) {
            result.error = '서버에서 LRC 데이터가 반환되지 않았습니다.';
            return result;
        }

        // LRC → synced / unsynced 변환
        const parsed = parseLRC(data.lrc);
        result.synced   = parsed.synced;
        result.unsynced = parsed.unsynced;

        if (!result.synced && !result.unsynced) {
            result.error = '자막 데이터를 파싱할 수 없습니다.';
            return result;
        }

        return result;
    }

    // ============================================
    // Addon Object
    // ============================================

    const YoutubeCaptionAddon = {
        ...ADDON_INFO,

        async init() {
            window.__ivLyricsDebugLog?.(`[${ADDON_ID}] Addon initialized (v${ADDON_INFO.version})`);
        },

        getSettingsUI,
        getLyrics,
    };

    // ============================================
    // Registration
    // ============================================

    const register = () => {
        if (window.LyricsAddonManager) {
            const ok = window.LyricsAddonManager.register(YoutubeCaptionAddon);
            if (ok) {
                window.__ivLyricsDebugLog?.(`[${ADDON_ID}] Registered with LyricsAddonManager`);
            }
        } else {
            setTimeout(register, 100);
        }
    };

    register();

    window.__ivLyricsDebugLog?.(`[${ADDON_ID}] Module loaded`);
})();
