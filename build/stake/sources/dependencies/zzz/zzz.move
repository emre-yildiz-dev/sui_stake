module zzz::zzz{
   public struct ZZZ has drop{} 

   // Constants
   const DECIMALS: u8 = 3;

   fun init(witness: ZZZ, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let decimals = DECIMALS;
        let symbol = b"ZZZ";
        let name = b"ZZZ";
        let description = b"ZZZ, the meme cat coin on the SUI Network";
        let icon_url = option::some(sui::url::new_unsafe_from_bytes(b"https://portomasonet.com/favicon.ico"));
        let supply = 900_000_000_000_000_000; 

        let (mut treasury_cap, metadata) = sui::coin::create_currency(
            witness,
            decimals,
            symbol,
            name,
            description,
            icon_url,
            ctx
        );

        transfer::public_freeze_object(metadata);
        sui::coin::mint_and_transfer(&mut treasury_cap, supply, sender, ctx);

        transfer::public_transfer(treasury_cap, sender);
   }
}