import json, urllib.request, time
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
def get(u):
    for n in range(3):
        try:
            r=urllib.request.Request(u,headers={'User-Agent':UA,'Referer':'https://music.163.com/'})
            return json.loads(urllib.request.urlopen(r,timeout=15).read())
        except Exception as e:
            time.sleep(3*(n+1))
    return {}
names={}
for area in (7,96,8,16,0):
    for typ in (1,2,3):
        for initial in [-1]+list(range(65,91))+[0]:
            for off in range(0, 300 if area==7 else 100, 100):
                j=get(f'https://music.163.com/api/v1/artist/list?type={typ}&area={area}&initial={initial}&limit=100&offset={off}')
                a=j.get('artists') or []
                for x in a:
                    names.setdefault(x['name'],{'alias':x.get('alias') or [], 'area':area, 'hot': initial==-1, 'mv':x.get('mvSize',0), 'albums':x.get('albumSize',0)})
                time.sleep(0.25)
                if not j.get('more') or not a: break
        print(area,typ,len(names),flush=True)
        json.dump(names,open('singers_netease.json','w'),ensure_ascii=False)
