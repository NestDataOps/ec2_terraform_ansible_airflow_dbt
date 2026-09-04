with source as (
    select * from {{ source('raw', 'raw_events') }}
),

flattened as (
    select
        event_id,
        event_type,
        source_file_name,
        ingested_at,
        event_payload:user_id::string        as user_id,
        event_payload:amount::float          as amount,
        event_payload:currency::string       as currency,
        event_payload:created_at::timestamp  as event_created_at
    from source
)

select * from flattened
