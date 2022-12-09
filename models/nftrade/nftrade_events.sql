{{ config(
    alias = 'events',
    partition_by = ['block_date'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_time', 'unique_trade_id']
    )
}}

WITH events AS (
    SELECT 
        'bnb' AS blockchain,
        'nftrade' AS project,
        'v1' AS version,
        evt_block_time AS block_time,
        null AS token_id,
        CASE   
            WHEN substring(makerAssetData FROM 1 FOR 34) IN ('0xa7cb5fb7000000000000000000000000') OR substring(takerAssetData FROM 1 FOR 34) IN ('0xa7cb5fb7000000000000000000000000') THEN 'erc1155' 
            ELSE 'erc721'
        END AS token_standard,
        'Single Item Trade' AS trade_type,
        1 AS number_of_items,
        'Buy' AS trade_category,
        CASE 
            WHEN makerAssetAmount = 1 THEN  makerAddress
            ELSE takerAddress
        END AS seller,
        CASE 
            WHEN makerAssetAmount = 1 THEN  takerAddress
            ELSE makerAddress
        END AS buyer,        
        CASE 
            WHEN makerAssetAmount = 1 THEN  takerAssetAmount
            ELSE makerAssetAmount
        END AS amount_raw,
        '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c' currency_contract,
        'BNB' currency_symbol,
        CASE 
            WHEN 
                makerAssetAmount = 1 
            THEN substring(replace(makerAssetData, substring(makerAssetData FROM 1 FOR 34), '0x') FROM 1 FOR 42) 
            ELSE substring(replace(takerAssetData, substring(takerAssetData FROM 1 FOR 34), '0x') FROM 1 FOR 42)
        END AS nft_contract_address,
        contract_address AS project_contract_address,
        evt_tx_hash AS tx_hash,
        evt_block_number AS block_number,
        evt_index
    FROM {{source('nftrade_bnb','NiftyProtocol_evt_Fill')}}
    WHERE substring(makerAssetData FROM 1 FOR 34) != '0x94cfcdd7000000000000000000000000' -- condition to remove transfer event
    {% if is_incremental() %}
    AND evt_block_time >= date_trunc("day", now() - interval '1 week')
    {% endif %}
)
    SELECT 
        events.blockchain,
        events.project,
        events.version,
        events.block_time,
        date_trunc('day', events.block_time) AS block_date,
        events.token_id,
        bnb_nft_tokens.name AS collection,
        events.amount_raw/POWER(10, bnb_bep20_tokens.decimals)*prices.price AS amount_usd,
        events.token_standard,
        CASE WHEN agg.name IS NOT NULL THEN 'Bundle Trade' ELSE 'Single Item Trade' END AS trade_type,
        CAST(events.number_of_items AS DECIMAL(38,0)) AS number_of_items,
        events.trade_category,
        'Trade' AS evt_type,
        events.seller,
        events.buyer,
        events.amount_raw/POWER(10, bnb_bep20_tokens.decimals) AS amount_original,
        CAST(events.amount_raw AS DECIMAL(38,0)) AS amount_raw,
        COALESCE(events.currency_symbol, bnb_bep20_tokens.symbol) AS currency_symbol,
        events.currency_contract,
        events.nft_contract_address,
        events.project_contract_address,
        agg.name AS aggregator_name,
        CASE WHEN agg.name IS NOT NULL THEN agg.contract_address END AS aggregator_address,
        events.tx_hash,
        events.block_number,
        bt.from AS tx_from,
        bt.to AS tx_to,
        events.block_number || events.tx_hash || events.evt_index AS unique_trade_id

    FROM events
    LEFT JOIN {{ ref('nft_aggregators') }} agg ON events.buyer=agg.contract_address AND agg.blockchain='bnb'
    LEFT JOIN {{ ref('tokens_erc20') }} bnb_bep20_tokens ON bnb_bep20_tokens.contract_address=events.currency_contract AND bnb_bep20_tokens.blockchain='bnb'
    LEFT JOIN {{ ref('tokens_nft') }} bnb_nft_tokens ON bnb_nft_tokens.contract_address=events.currency_contract AND bnb_nft_tokens.blockchain='bnb'
    LEFT JOIN {{ source('prices', 'usd') }} prices ON prices.minute=date_trunc('minute', events.block_time)
    AND (prices.contract_address=events.currency_contract AND prices.blockchain=events.blockchain)
        {% if is_incremental() %}
        AND prices.minute >= date_trunc("day", now() - interval '1 week')
        {% endif %}
    INNER JOIN {{ source('bnb','transactions') }} bt ON bt.hash=events.tx_hash
    AND bt.block_time=events.block_time
        {% if is_incremental() %}
        AND bt.block_time >= date_trunc("day", now() - interval '1 week')
        {% endif %}