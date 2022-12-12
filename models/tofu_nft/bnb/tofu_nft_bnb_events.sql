
WITH decoded_detail AS(
    SELECT 
        call_tx_hash,
        call_block_time,
        call_block_number,
        contract_address,
        from_json(detail, "intentionHash STRING, signer STRING, txDeadline INT, salt STRING, id INT, opcode INT, caller STRING, currency STRING, price LONG, incentiveRate INT, settlement STRING, bundle STRING, deadline LONG") detail
    FROM tofu_nft_bnb.MarketNG_call_run
    WHERE date_trunc('day',call_block_time) >= timestamp '2022-01-01'
)
    SELECT 
        call_tx_hash,
        call_block_time,
        call_block_number,
        contract_address,
        detail.currency,
        detail.price,
        detail.incentiveRate,
        detail.settlement,
        detail.bundle bundle
    FROM decoded_detail
