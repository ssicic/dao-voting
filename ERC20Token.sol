pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Token is ERC20 {
    address private owner;
    
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        owner = msg.sender;
    }
    
    function mint(address account, uint256 amount) external {
        require(msg.sender == owner, "Only owner can mint tokens");
        _mint(account, amount);
    }
    
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}