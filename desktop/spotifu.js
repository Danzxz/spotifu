/* Spotifu: extends Spotify's player, never creates a second audio element. */
function findLocalTrack(saved, tracks) {
    const normalize = s => String(s).normalize('NFKC').trim().toLocaleLowerCase();
    return tracks.find(track => track.uri?.startsWith('spotify:local:') &&
        normalize(track.name) === normalize(saved.title) &&
        track.artists?.some(artist => normalize(artist.name) === normalize(saved.artist)) &&
        track.album?.name === 'Spotifu' &&
        Math.abs((track.duration?.milliseconds || 0) / 1000 - saved.duration) <= 2) || null;
}
if (typeof module !== 'undefined') module.exports = {findLocalTrack};

if (typeof window !== 'undefined') (async function spotifu() {
    while (!window.Spicetify?.Player || !Spicetify.Playbar || !Spicetify.Platform?.LocalFilesAPI) {
        await new Promise(resolve => setTimeout(resolve, 500));
    }
    const configuration = window.SPOTIFU_CONFIG;
    if (!configuration?.token) { Spicetify.showNotification('Spotifu: сервер загрузки ещё не настроен', true); return; }
    const localAPI = Spicetify.Platform.LocalFilesAPI;
    let busy = false;
    let redirecting = false;
    let mappings;
    try { mappings = JSON.parse(Spicetify.LocalStorage.get('spotifu.native-map') || '{}'); } catch { mappings = {}; }
    async function api(path, body) {
        const response = await fetch(configuration.endpoint + path, {
            method: body ? 'POST' : 'GET',
            headers: {Authorization: 'Bearer ' + configuration.token, ...(body ? {'Content-Type':'application/json'} : {})},
            ...(body ? {body: JSON.stringify(body)} : {})
        });
        const value = await response.json();
        if (!response.ok) throw new Error(value.error || 'Ошибка сервера');
        return value;
    }
    async function indexLibrary() {
        const library = await api('/library');
        localAPI.setIsEnabled(true);
        await localAPI.addFolder({path: library.folder});
        const tracks = await localAPI.getTracks();
        for (const saved of library.tracks) {
            const local = findLocalTrack(saved, tracks);
            if (local) mappings['spotify:track:' + saved.id] = {uri:local.uri, lyrics:saved.lyrics, title:saved.title, artist:saved.artist};
        }
        Spicetify.LocalStorage.set('spotifu.native-map', JSON.stringify(mappings));
    }
    const button = new Spicetify.Playbar.Button('Скачать', 'download', async () => {
        if (busy) return;
        const item = Spicetify.Player.data?.item;
        if (!item?.uri?.startsWith('spotify:track:')) { Spicetify.showNotification('Открой песню Spotify'); return; }
        busy = true; button.disabled = true;
        try {
            const metadata = item.metadata || {};
            const request = {id:item.uri.split(':')[2], title:item.name || metadata.title,
                artist:item.artists?.[0]?.name || metadata.artist_name,
                duration:(item.duration?.milliseconds || Number(metadata.duration) || Spicetify.Player.getDuration()) / 1000};
            const {job} = await api('/auto-download', request);
            Spicetify.showNotification('Spotifu: ищу и скачиваю…');
            for (let attempt = 0; attempt < 300; attempt++) {
                const state = await api('/jobs/' + job);
                if (state.status === 'failed') throw new Error(state.error);
                if (state.status === 'ready') {
                    for (let scan = 0; scan < 10; scan++) {
                        await indexLibrary();
                        if (mappings[item.uri]) break;
                        await new Promise(resolve => setTimeout(resolve, 1000));
                    }
                    if (!mappings[item.uri]) throw new Error('Файл скачан, но Spotify ещё не проиндексировал его');
                    button.icon = 'downloaded'; button.active = true;
                    Spicetify.showNotification(state.lyrics ? 'Загружено с текстом' : 'Загружено. Текст не найден.');
                    return;
                }
                await new Promise(resolve => setTimeout(resolve, 2000));
            }
            throw new Error('Загрузка не завершилась вовремя');
        } catch (error) { Spicetify.showNotification('Spotifu: ' + error.message, true); }
        finally { busy = false; button.disabled = false; }
    });
    Spicetify.Player.addEventListener('songchange', async () => {
        if (redirecting) return;
        const uri = Spicetify.Player.data?.item?.uri;
        const mapping = mappings[uri];
        const downloaded = !!mapping || Object.values(mappings).some(m => m.uri === uri);
        button.icon = downloaded ? 'downloaded' : 'download';
        button.active = downloaded;
        if (!mapping) return;
        try {
            redirecting = true;
            await Spicetify.Player.playUri(mapping.uri);
        } catch (error) { Spicetify.showNotification('Spotifu: локальное воспроизведение недоступно', true); }
        finally { redirecting = false; }
    });
    new Spicetify.Menu.Item('Spotifu · Скачанное', false, () => Spicetify.Platform.History.push('/local-files'), 'download').register();
    try { await indexLibrary(); } catch { /* Cached mappings still work offline. */ }
})();
