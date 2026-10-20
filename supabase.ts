import {createBrowserClient} from '@supabase/ssr'
export function db(){
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL, key=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
 if(!url||!key) throw Error('Missing Supabase settings. See .env.example')
 return createBrowserClient(url,key)
}
