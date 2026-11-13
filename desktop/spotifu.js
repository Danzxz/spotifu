/* Spotifu: extends Spotify's player, never creates a second audio element. */
function findLocalTrack(saved, tracks) {
    const normalize = s => String(s).normalize('NFKC').trim().toLocaleLowerCase();
    return tracks.find(track => track.uri?.startsWith('spotify:local:') &&
        normalize(track.name) === normalize(saved.title) &&
        track.artists?.some(artist => normalize(artist.name) === normalize(saved.artist)) &&
        track.album?.name === 'Spotifu' &&
        Math.abs((track.duration?.milliseconds || 0) / 1000 - saved.duration) <= 2) || null;
}
function downloadRequest(item) {
    const metadata = item.metadata || {};
    const artists = item.artists?.items || item.artists || [];
    return {id: item.uri?.split(':')[2], title:item.name || metadata.title,
        artist:artists[0]?.name || artists[0]?.profile?.name || metadata.artist_name,
        duration:(item.duration?.milliseconds || item.duration?.totalMilliseconds || Number(metadata.duration) || 0)/1000};
}
if (typeof module !== 'undefined') module.exports = {findLocalTrack, downloadRequest};

if (typeof window !== 'undefined') (async function spotifu() {
    while (!window.Spicetify?.Player?.origin?.play || !Spicetify.Playbar || !Spicetify.ContextMenu?.Item || !Spicetify.Menu?.SubMenu || !Spicetify.Platform?.LocalFilesAPI) {
        await new Promise(resolve => setTimeout(resolve, 500));
    }
    const configuration = window.SPOTIFU_CONFIG;
    if (!configuration?.token) { Spicetify.showNotification('Spotifu: сервер загрузки ещё не настроен', true); return; }
    const localAPI = Spicetify.Platform.LocalFilesAPI;
    const allLocalTracks=localAPI.getTracks.bind(localAPI);
    function isDownloaded(uri){return !!mappings[uri] || Object.values(mappings).some(m=>m.uri===uri);}
    function computerView(){return Spicetify.Platform.History.location.search?.includes('spotifu=computer');}
    localAPI.getTracks=async(...args)=>{
        const tracks=await allLocalTracks(...args);
        return computerView()?tracks:tracks.filter(t=>isDownloaded(t.uri));
    };
    let busy = false;
    let redirecting = false;
    let mappings;
    try { mappings = JSON.parse(Spicetify.LocalStorage.get('spotifu.native-map') || '{}'); } catch { mappings = {}; }
    let scannedTotal=localAPI._totalLength || 0;
    Object.defineProperty(localAPI,'_totalLength',{configurable:true,
        get:()=>computerView()?scannedTotal:new Set(Object.values(mappings).map(m=>m.uri)).size,
        set:value=>{scannedTotal=value;}});
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
        const tracks = await allLocalTracks();
        const savedIDs=new Set(library.tracks.map(t=>'spotify:track:'+t.id));
        for(const uri of Object.keys(mappings))if(!savedIDs.has(uri))delete mappings[uri];
        for (const saved of library.tracks) {
            const local = findLocalTrack(saved, tracks);
            if (local) mappings['spotify:track:' + saved.id] = {uri:local.uri, lyrics:saved.lyrics, title:saved.title, artist:saved.artist};
        }
        Spicetify.LocalStorage.set('spotifu.native-map', JSON.stringify(mappings));
    }
    let groups;
    try { groups = JSON.parse(Spicetify.LocalStorage.get('spotifu.groups') || '{}'); } catch { groups = {}; }
    const saveGroups = () => Spicetify.LocalStorage.set('spotifu.groups', JSON.stringify(groups));
    new Spicetify.Menu.Item('Скачанное · Все песни',false,()=>Spicetify.Platform.History.push('/local-files?spotifu=downloads'),'download').register();
    const downloadedMenu = new Spicetify.Menu.SubMenu('Скачанное · Spotifu', [], 'download');
    downloadedMenu.register();
    const groupMenus = new Set();
    function registerGroup(group) {
        if (groupMenus.has(group.uri)) return;
        groupMenus.add(group.uri);
        downloadedMenu.addItem(new Spicetify.Menu.Item(group.name, false, () => {
            if (group.playlist) Spicetify.Platform.History.push('/playlist/' + group.playlist.split(':')[2]);
            else Spicetify.showNotification('Пока нет успешно загруженных песен');
        }, 'download'));
    }
    Object.values(groups).forEach(registerGroup);
    async function downloadOne(item) {
        const request = downloadRequest(item);
        if (!request.id || !request.title || !request.artist || !(request.duration > 0)) throw new Error('Не хватает метаданных песни');
        if (mappings[item.uri]) return mappings[item.uri].uri;
        const {job} = await api('/auto-download', request);
        for (let attempt=0; attempt<300; attempt++) {
            const state = await api('/jobs/' + job);
            if (state.status === 'failed') throw new Error(state.error);
            if (state.status === 'ready') {
                for (let scan=0; scan<20; scan++) {
                    await indexLibrary();
                    if (mappings[item.uri]) return mappings[item.uri].uri;
                    await new Promise(resolve=>setTimeout(resolve,1000));
                }
                throw new Error('Файл сохранён, Spotify ещё не проиндексировал его');
            }
            await new Promise(resolve=>setTimeout(resolve,2000));
        }
        throw new Error('Истекло время загрузки');
    }
    async function collection(uri) {
        const items=[];
        if (uri.startsWith('spotify:album:')) {
            let total=Infinity;
            for(let offset=0;offset<total;offset+=50) {
                const r=await Spicetify.GraphQL.Request(Spicetify.GraphQL.Definitions.queryAlbumTracks,{uri,offset,limit:50});
                const page=r.data?.albumUnion?.tracksV2;
                if(!page) throw new Error('Spotify не вернул список песен альбома');
                total=page.totalCount;
                items.push(...page.items.map(x=>x.track));
                if(!page.items.length)break;
            }
        } else {
            let total=Infinity;
            for(let offset=0;offset<total;offset+=100) {
                const page=await Spicetify.Platform.PlaylistAPI.getContents(uri,{offset,limit:100});
                total=page.totalLength;items.push(...page.items.filter(x=>x.type==='track'));
                if(!page.items.length)break;
            }
        }
        return items;
    }
    async function resolveTrack(uri) {
        const current=Spicetify.Player.data?.item;
        if(current?.uri===uri) return current;
        const path=Spicetify.Platform.History.location.pathname;
        const match=path.match(/^\/(album|playlist)\/([^/]+)/);
        if(match) {
            const item=(await collection('spotify:'+match[1]+':'+match[2])).find(x=>x.uri===uri);
            if(item)return item;
        }
        // Liked songs use the native collection service, not public Web API.
        // Public /v1/tracks was rate-limited (429) even for an already-visible row.
        if(path.startsWith('/collection/tracks') && Spicetify.Platform.LibraryAPI?.getTracks) {
            for(let offset=0; ;offset+=100) {
                const page=await Spicetify.Platform.LibraryAPI.getTracks({offset,limit:100});
                const item=page.items.find(x=>x.uri===uri);
                if(item)return item;
                if(!page.items.length || offset+page.items.length>=page.totalLength)break;
            }
        }
        throw new Error('Не удалось получить данные песни из текущего списка. Открой её альбом и повтори');
    }
    async function collectionName(uri) {
        if(uri.startsWith('spotify:album:')) {
            const r=await Spicetify.GraphQL.Request(Spicetify.GraphQL.Definitions.getAlbumNameAndTracks,{uri,offset:0,limit:1});
            return r.data?.albumUnion?.name || uri;
        }
        const r=await Spicetify.Platform.PlaylistAPI.getMetadata(uri);
        return r.name || uri;
    }
    const pending=[];
    const scheduled=new Set();
    let draining=null;
    let lastStatus='Нет активных загрузок';
    const queueMenu=new Spicetify.Menu.Item('Загрузки: нет активных',false,()=>Spicetify.showNotification(lastStatus),'download');
    queueMenu.register();
    function status(text) {
        lastStatus=text;
        queueMenu.name='Загрузки: '+text;
        button.label=text;
    }
    function enqueue(uris) {
        for(const uri of uris)if(!scheduled.has(uri)){pending.push(uri);scheduled.add(uri);}
        if(draining){status(lastStatus+' · в очереди: '+pending.length);return draining;}
        draining=(async()=>{
            try{while(pending.length){const uri=pending.shift();try{await processBatch([uri]);}finally{scheduled.delete(uri);}}}
            finally{draining=null;}
        })();
        return draining;
    }
    async function processBatch(uris) {
        busy=true;
        try {
            for(const uri of uris) {
                const isCollection=/^spotify:(album|playlist):/.test(uri);
                const items=isCollection?await collection(uri):[await resolveTrack(uri)];
                const name=isCollection ? await collectionName(uri) : items[0].album?.name || items[0].metadata?.album_title || 'Отдельные песни';
                const groupURI=isCollection?uri:items[0].album?.uri||items[0].metadata?.album_uri||'spotifu:singles';
                const group=groups[groupURI] ||= {uri:groupURI,name,tracks:{},total:0};
                group.total=Math.max(group.total,items.length);registerGroup(group);saveGroups();
                let failed=0;
                for(let i=0;i<items.length;i++) {
                    status('Обрабатывается '+(i+1)+' из '+items.length+' · '+items[i].name);
                    Spicetify.showNotification(lastStatus);
                    try {
                        const local=await downloadOne(items[i]);
                        if(!group.playlist) {
                            group.playlist=await Spicetify.Platform.RootlistAPI.createPlaylist('Скачано · '+name,{after:'end'});
                            if(!group.playlist)throw new Error('Не удалось создать список скачанного');
                            await Spicetify.Platform.PlaylistAPI.updateDetails(group.playlist,{description:'Локальные загрузки Spotifu · '+groupURI});
                        }
                        if(group.tracks[items[i].uri]?.status!=='ready')await Spicetify.Platform.PlaylistAPI.add(group.playlist,[local],{after:'end'});
                        group.tracks[items[i].uri]={uri:local,status:'ready'};
                        status('Сохранено: '+items[i].name);
                    } catch(error) {failed++;group.tracks[items[i].uri]={status:'failed',error:error.message};status('Ошибка: '+items[i].name+' · '+error.message);}
                    saveGroups();
                }
                status('Сохранено '+(items.length-failed)+' из '+items.length+(failed?' · ошибок: '+failed:''));
                Spicetify.showNotification(lastStatus,failed>0);
            }
        }catch(error){Spicetify.showNotification('Spotifu: '+error.message,true);}
        finally{busy=false;button.disabled=false;}
    }
    // Native play requests retain their context/options. Local files must run
    // on this computer rather than the user's active Spotify Connect phone.
    const nativePlayer=Spicetify.Player.origin;
    const originalPlay=nativePlayer.play.bind(nativePlayer);
    nativePlayer.play=async function(target, context, options) {
        const mapped=mappings[target?.uri];
        const next=mapped?{...target,uri:mapped.uri}:target;
        const local=next?.uri?.startsWith('spotify:local:') || next?.uri?.includes('local-files') || options?.skipTo?.uri?.startsWith('spotify:local:') || Object.values(groups).some(g=>g.playlist===next?.uri);
        if(local && Spicetify.Platform.ConnectAPI.getState().activeDevice?.isLocal!==true) {
            await Spicetify.Platform.ConnectAPI.pullToLocal({interactionId:'spotifu-local-play'});
        }
        return originalPlay(next,context,options);
    };
    const button = new Spicetify.Playbar.Button('Скачать', 'download', () => {
        const uri=Spicetify.Player.data?.item?.uri;
        if(uri?.startsWith('spotify:track:'))enqueue([uri]);
    });
    async function removeDownloads(uris) {
        try {
            for(const uri of uris) {
                const remote=mappings[uri]?uri:Object.keys(mappings).find(k=>mappings[k].uri===uri);
                if(!remote)continue;
                const local=mappings[remote].uri;
                await api('/remove-download',{id:remote.split(':')[2]});
                delete mappings[remote];
                for(const group of Object.values(groups)) {
                    const had=group.tracks[remote]?.status==='ready';
                    delete group.tracks[remote];
                    if(had && group.playlist) {
                        try { await Spicetify.Platform.PlaylistAPI.remove(group.playlist,[{uid:'',uri:local}]); }
                        catch { Spicetify.showNotification('Файл удалён; список Spotify обновится при подключении',true); }
                    }
                }
                // Deleted files become unavailable in native playlists; never
                // delete arbitrary computer files or unrelated library entries.
                Spicetify.LocalStorage.set('spotifu.native-map',JSON.stringify(mappings));saveGroups();
            }
            Spicetify.showNotification('Удалено из скачанного Spotifu');
            if(Spicetify.Platform.History.location.pathname==='/local-files')Spicetify.Platform.History.push('/local-files?spotifu=downloads');
        }catch(error){Spicetify.showNotification(error.message,true);}
    }
    new Spicetify.ContextMenu.Item('Скачать', enqueue,
        uris => uris.length>0 && uris.every(uri=>/^spotify:(track|album|playlist):/.test(uri)) && !uris.every(isDownloaded), 'download').register();
    new Spicetify.ContextMenu.Item('Удалить из скачанного', removeDownloads,
        uris => uris.length>0 && uris.every(isDownloaded), 'trash').register();
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
    new Spicetify.Menu.Item('Локальные файлы компьютера', false, () => Spicetify.Platform.History.push('/local-files?spotifu=computer'), 'download').register();
    window.Spotifu = {download:enqueue, remove:removeDownloads, get busy(){return busy;}, get status(){return lastStatus;}, get queued(){return pending.length;}, get groups(){return groups;}};
    try { await indexLibrary(); } catch { /* Cached mappings still work offline. */ }
})();
