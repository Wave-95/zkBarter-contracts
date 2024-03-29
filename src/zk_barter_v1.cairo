%lang starknet
from cairo_contracts.src.openzeppelin.token.erc721.interfaces.IERC721 import IERC721
from cairo_contracts.src.openzeppelin.access.ownable import Ownable
from cairo_contracts.src.openzeppelin.upgrades.library import Proxy
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import (
    BitwiseBuiltin,
    HashBuiltin,
)
from starkware.cairo.common.cairo_keccak.keccak import keccak_felts, finalize_keccak
from starkware.cairo.common.math import assert_le
from starkware.starknet.common.syscalls import (
    get_block_timestamp,
    get_caller_address,
    library_call, 
)
from starkware.cairo.common.uint256 import Uint256

#
# Events
#

@event
func trade_request_opened(
    id : Uint256,
    requestor_address : felt,
    requestee_address : felt,
    token_a_address : felt,
    token_b_address : felt,
    token_a_id: Uint256,
    token_b_id: Uint256,
    expiration: felt,
):
end

@event
func trade_request_closed(id : Uint256):
end

@event
func trade_request_matched(id : Uint256):
end

#
# Consts
#

const DEFAULT_REQUESTEE_ADDRESS = 0

#
# Structs
#

struct TradeRequest:
    member requestor_address : felt
    member requestee_address : felt
    member token_a_address : felt
    member token_b_address : felt
    member token_a_id : Uint256
    member token_b_id : Uint256
    member expiration : felt
end

struct StatusEnum:
    member CLOSED : felt
    member OPEN : felt
    member MATCHED : felt
end

#
# Storage variables
#

@storage_var
func is_trading_live() -> (res : felt):
end

@storage_var
func trade_requests(trade_request_id : Uint256) -> (res : TradeRequest):
end

@storage_var
func trade_request_statuses(trade_request_id : Uint256) -> (res : felt):
end

#
# Intializer (to be called once from a proxy delegate contract)
#

@external
func initializer{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr
}(proxy_admin : felt):
    Proxy.initializer(proxy_admin=proxy_admin)
    is_trading_live.write(value=TRUE)
    return ()
end

#
# External functions
#

#Opens a 1:1 NFT trade request. The requestor must own Token A to initiate a trade request. Set expiration to 0 for no expiration date.
@external
func open_trade_request{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    bitwise_ptr : BitwiseBuiltin*,
    range_check_ptr
}(
    token_a_address : felt,
    token_b_address : felt,
    token_a_id : Uint256,
    token_b_id : Uint256,
    isPrivate : felt,
    expiration : felt
) -> (trade_request_id : Uint256):
    alloc_locals

    #Check for ownership
    let (caller) = get_caller_address()
    let (owner_of_token_a) = IERC721.ownerOf(contract_address=token_a_address, tokenId=token_a_id)
    with_attr error_message("Requestor does not own the ERC721 token for trade"):
        assert caller = owner_of_token_a
    end

    #Set requestee address to owner of token B if trade request is private. If public, set to 0 (anyone address holding token B can execute match)
    #https://www.cairo-lang.org/docs/how_cairo_works/builtins.html#revoked-implicit-arguments
    local requestee_address
    if isPrivate == TRUE:
        let (owner_of_token_b) = IERC721.ownerOf(contract_address=token_b_address, tokenId=token_b_id)
        requestee_address = owner_of_token_b
        tempvar syscall_ptr = syscall_ptr
        tempvar range_check_ptr = range_check_ptr
    else:
        requestee_address = DEFAULT_REQUESTEE_ADDRESS
        tempvar syscall_ptr = syscall_ptr
        tempvar range_check_ptr = range_check_ptr
    end

    #Get the trade request id for a given payload
    let (payload : felt*) = alloc()
    assert payload[0] = caller
    assert payload[1] = requestee_address
    assert payload[2] = token_a_address
    assert payload[3] = token_b_address
    assert payload[4] = token_a_id.low
    assert payload[5] = token_a_id.high
    assert payload[6] = token_b_id.low
    assert payload[7] = token_b_id.high
    let (trade_request_id) = _get_trade_request_id(n_elements=8, elements=payload)

    #Check if non-expired trade request is already open
    let (trade_request_status) = trade_request_statuses.read(trade_request_id=trade_request_id)
    let (trade_request) = trade_requests.read(trade_request_id=trade_request_id)
    if trade_request_status == StatusEnum.OPEN:
        if trade_request.expiration != 0:
            with_attr error_message("Trade request already exists"):
                assert 1 = 0
            end
        end
    end
    
    #Open a new trade request
    local tr : TradeRequest = TradeRequest(
        requestor_address=caller,
        requestee_address=requestee_address,
        token_a_address=token_a_address,
        token_b_address=token_b_address,
        token_a_id=token_a_id,
        token_b_id=token_b_id,
        expiration=expiration
    )
    trade_requests.write(trade_request_id=trade_request_id, value=tr)
    trade_request_statuses.write(trade_request_id=trade_request_id, value=StatusEnum.OPEN)

    trade_request_opened.emit(
        id=trade_request_id,
        requestor_address=caller,
        requestee_address=requestee_address,
        token_a_address=token_a_address,
        token_b_address=token_b_address,
        token_a_id=token_a_id,
        token_b_id=token_b_id,
        expiration=expiration
    )

    return (trade_request_id=trade_request_id)
end

# Closes an open trade request
@external
func close_trade_request{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(trade_request_id : Uint256) -> ():
    #Check if trade request was opened by caller
    let (caller) = get_caller_address()
    let (trade_request) = trade_requests.read(trade_request_id=trade_request_id)
    with_attr error_message("Cannot close a trade request that does not exist or does not belong to caller"):
        assert caller = trade_request.requestor_address
    end
    let (trade_request_status) = trade_request_statuses.read(trade_request_id=trade_request_id)
    with_attr error_message("Trade request is not in OPEN status"):
        assert trade_request_status = StatusEnum.OPEN
    end
    trade_request_statuses.write(trade_request_id=trade_request_id, value=StatusEnum.CLOSED)
    trade_request_closed.emit(id=trade_request_id)
    return()
end

# Matches against an open trade request
@external
func match_trade_request{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(
    trade_request_id : Uint256
) -> ():
    alloc_locals
    _assert_trading_is_live()
    #Check that trade request is open
    let (trade_request) = trade_requests.read(trade_request_id=trade_request_id)
    let (trade_request_status) = trade_request_statuses.read(trade_request_id=trade_request_id)
    with_attr error_message("Trade request is no longer valid"):
        assert trade_request_status = StatusEnum.OPEN
    end

    #Check trade request is not expired
    let (timestamp) = get_block_timestamp()
    if trade_request.expiration != 0:
        with_attr error_message("Trade request is expired"):
            assert_le(trade_request.expiration, timestamp)
        end
        tempvar syscall_ptr = syscall_ptr
        tempvar range_check_ptr = range_check_ptr
    else:
        tempvar syscall_ptr = syscall_ptr
        tempvar range_check_ptr = range_check_ptr
    end

    #Check for ownership
    let (caller) = get_caller_address()
    let (owner) = IERC721.ownerOf(contract_address=trade_request.token_b_address, tokenId=trade_request.token_b_id)
    with_attr error_message("Matcher is not the owner of ERC721 token for trade"):
        assert caller = owner
    end

    #Enforce private trades
    if trade_request.requestee_address != 0:
        assert trade_request.requestee_address = caller
    end

    #Swap NFTs
    IERC721.transferFrom(
        contract_address=trade_request.token_a_address,
        from_=trade_request.requestor_address,
        to=caller,
        tokenId=trade_request.token_a_id
    )
    IERC721.transferFrom(
        contract_address=trade_request.token_b_address,
        from_=caller,
        to=trade_request.requestor_address,
        tokenId=trade_request.token_b_id
    )

    #Update trade request status to MATCHED
    trade_request_statuses.write(trade_request_id=trade_request_id, value=StatusEnum.MATCHED)
    trade_request_matched.emit(
        id=trade_request_id
    )
    return ()
end

@view
func get_trade_request{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr    
    }(trade_request_id : Uint256) -> (res : TradeRequest):
    let (trade_request) = trade_requests.read(trade_request_id=trade_request_id)
    return (res=trade_request)
end

@view
func get_trade_request_status{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr 
    }(trade_request_id : Uint256) -> (res : felt):
    let (status) = trade_request_statuses.read(trade_request_id=trade_request_id)
    return (res=status)
end

@external
func update_is_trading_live{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr 
    }(bool : felt):
    Proxy.assert_only_admin()
    is_trading_live.write(value=bool)
    return ()
end

#
# Upgrades
#

@external
func upgrade{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(new_implementation: felt):
    Proxy.assert_only_admin()
    Proxy._set_implementation_hash(new_implementation)
    return ()
end

#
# Admin
#

@external
func set_admin{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}(new_admin : felt):
    Proxy.assert_only_admin()
    Proxy._set_admin(new_admin=new_admin)
    return()
end

@view
func get_admin{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    range_check_ptr
}() -> (res : felt):
    let (res) = Proxy.get_admin()
    return(res)
end

#
# Internal
#

func _get_trade_request_id{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    bitwise_ptr : BitwiseBuiltin*, 
    range_check_ptr
}(n_elements : felt, elements : felt*) -> (res : Uint256):
    #https://github.com/starkware-libs/cairo-lang/blob/master/src/starkware/cairo/common/cairo_keccak/keccak.cairo
    alloc_locals
    let (keccak_ptr : felt*) = alloc()
    local keccak_ptr_start : felt* = keccak_ptr
    let (keccak_hash) = keccak_felts{keccak_ptr=keccak_ptr}(n_elements=n_elements, elements=elements)
    finalize_keccak(keccak_ptr_start=keccak_ptr_start, keccak_ptr_end=keccak_ptr)
    return (res=keccak_hash)
end

func _assert_trading_is_live{
    syscall_ptr : felt*, 
    pedersen_ptr : HashBuiltin*, 
    range_check_ptr
}():
    let (res) = is_trading_live.read()
    with_attr error_message("Trading is not live"):
        assert res = TRUE
    end
    return ()
end
