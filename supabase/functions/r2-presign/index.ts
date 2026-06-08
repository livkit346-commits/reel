import { serve } from "https://deno.land/std@0.168/http/server.ts"
import { S3Client, PutObjectCommand } from "npm:@aws-sdk/client-s3"
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 1. Get user authorization from headers
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'No authorization header' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // 2. Parse request body
    const { filename, contentType } = await req.json()
    if (!filename || !contentType) {
      return new Response(JSON.stringify({ error: 'filename and contentType are required' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    // 3. Read environment variables from Supabase
    const accessKeyId = Deno.env.get('R2_ACCESS_KEY_ID')
    const secretAccessKey = Deno.env.get('R2_SECRET_ACCESS_KEY')
    const endpoint = Deno.env.get('R2_ENDPOINT')
    const bucketName = Deno.env.get('R2_BUCKET_NAME')
    const publicUrlBase = Deno.env.get('R2_PUBLIC_URL') // e.g. https://pub-xxxx.r2.dev

    if (!accessKeyId || !secretAccessKey || !endpoint || !bucketName) {
      return new Response(
        JSON.stringify({ error: 'R2 storage credentials are not configured in Supabase environment' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // 4. Configure S3 Client for Cloudflare R2
    const s3Client = new S3Client({
      region: 'auto',
      endpoint: endpoint,
      credentials: {
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
      },
    })

    // Generate unique object key (e.g. UUID-filename)
    const fileId = crypto.randomUUID()
    const objectKey = `${fileId}-${filename}`

    // Create S3 PUT command
    const command = new PutObjectCommand({
      Bucket: bucketName,
      Key: objectKey,
      ContentType: contentType,
    })

    // 5. Generate presigned URL valid for 300 seconds (5 minutes)
    const uploadUrl = await getSignedUrl(s3Client, command, { expiresIn: 300 })

    // Build the public link URL to read/play the file
    const publicUrl = publicUrlBase ? `${publicUrlBase}/${objectKey}` : '';

    return new Response(
      JSON.stringify({
        uploadUrl,
        objectKey,
        publicUrl,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
