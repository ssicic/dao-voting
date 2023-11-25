// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./Proposal.sol";
import "./MyToken.sol";

contract QuadraticVoting is Ownable{
    enum ProposalStatus {Pending, Approved, Rejected, Cancelled}

    struct Proposal {
        string title;
        string description;
        uint256 budget;
        uint256 proposalId;
        uint votes;
        IExecutableProposal executableProposal;
        address creator;
        address[] voters;
        uint256 availableBudget;
        ProposalStatus status;
    }

    MyToken private token; 
    bool private votingOpen;
    bool private refundingOpen;

    uint256 proposalsNum;
    uint256 participantsNum;
    uint256 tokenPrice;
    uint256 maxTokens;
    uint256 totalBudget;

    Proposal[] proposals;
    mapping(address => uint256) isParticipant;
    mapping(uint => mapping(address => uint)) votes;

    uint256[] signalingProposals;
    uint256[] approvedProposals; 
    uint256[] pendingProposals;

    constructor(uint256 _tokenPrice, uint256 _maxTokens) {
        token = new MyToken();
        votingOpen = false;
        refundingOpen = false;
        tokenPrice = _tokenPrice;
        maxTokens = _maxTokens;
        transferOwnership(msg.sender);
        proposalsNum = 0;
        participantsNum = 0;
    }

    modifier onlyParticipant() {
        require(isParticipant[msg.sender] != 0, "Not a participant");
        _;
    }

    modifier onlyCreator(uint256 _proposalId) {
        require(proposals[_proposalId].creator == msg.sender, "Not the creator");
        _;
    }

    modifier voteOpen(){
        require(votingOpen == true, "Voting must be open");
        _;
    }

    modifier refundOpen(){
        require(refundingOpen == true, "Refund session must be open");
        _;
    }

    function addParticipant() external payable {
        require(isParticipant[msg.sender] == 0, "Already a participant");

        uint256 tokensToMint = (msg.value * (10 ** 18)) / tokenPrice;
        require(tokensToMint >= 1, "Insufficient Ether to buy at least one token");
        token.mint(msg.sender, tokensToMint);

        participantsNum++;
        isParticipant[msg.sender] = 1; 
    }

    function removeParticipant() external onlyParticipant {
        participantsNum--;
        isParticipant[msg.sender] = 0;
    }

    function addProposal(string memory _title, string memory _description, uint256 _budget, address _proposalAddress) external onlyParticipant voteOpen returns (uint256) {
        uint proposalId = proposalsNum;
        Proposal memory newProposal = Proposal(_title, _description, _budget, proposalId, 0, IExecutableProposal(_proposalAddress), msg.sender, new address[](0), 0, ProposalStatus.Pending);
        proposals.push(newProposal);
        
        if (_budget == 0) {
            signalingProposals.push(proposalsNum);
        } else {
            pendingProposals.push(proposalsNum);
        }
        proposalsNum++;
        return proposalsNum-1;
    }

    function cancelProposal(uint256 _proposalId) external onlyParticipant onlyCreator(_proposalId) voteOpen {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");

        proposal.status = ProposalStatus.Cancelled;

        address[] storage votersP = proposal.voters;
        mapping(address => uint256) storage votesProposal = votes[_proposalId];

        for (uint256 i = 0; i < votersP.length; i++) {
            address voter = votersP[i];
            uint256 numVotes = votesProposal[voter];
            if (numVotes > 0) {
                uint256 refund = (numVotes * numVotes) / tokenPrice;
                votes[_proposalId][voter] = 0;
                token.transfer(voter, refund);
            }
        }
    }

    function buyTokens() external payable onlyParticipant {
        uint256 tokenAmount = (msg.value * (10 ** 18)) / tokenPrice;
        token.mint(msg.sender, tokenAmount);
    }   

    function sellTokens(uint256 _amount) external onlyParticipant {
        uint256 tokenValue = (_amount / (10 ** 18)) * tokenPrice;
        require(token.balanceOf(msg.sender) >= tokenValue, "Insufficient token balance");
        payable(msg.sender).transfer(tokenValue);
        token.burn(msg.sender, _amount);
    }

    function getERC20() public view returns (address) {
        return address(token);
    }

    function openVoting() external payable onlyOwner {
        require(votingOpen != true, "Voting already open");

        totalBudget = msg.value;
        votingOpen = true;
    }

    function stake(uint _proposalId, uint _numVotes) external onlyParticipant voteOpen {
        Proposal storage proposal = proposals[_proposalId];
        uint256 currVotes = votes[_proposalId][msg.sender];

        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");
        uint256 allVotes = currVotes + _numVotes;
        uint256 requiredTokens = allVotes * allVotes - (currVotes * currVotes) * (10 ** 18);

        uint256 allowance = token.allowance(msg.sender, address(this));
        require(allowance >= requiredTokens, "Tokens not approved");
        require(token.balanceOf(msg.sender) >= requiredTokens, "Insufficient tokens");

        token.transferFrom(msg.sender, address(this), requiredTokens);
        proposal.availableBudget += requiredTokens;
        proposal.votes += _numVotes;
        votes[_proposalId][msg.sender] += _numVotes;
        if (proposals[_proposalId].budget != 0) {
            _checkAndExecuteProposal(_proposalId, proposal.votes);
        }
    }

    function withdrawFromProposal(uint _proposalId, uint _numVotes) external onlyParticipant voteOpen {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.Pending, "Proposal not pending");
        uint256 currVotes = votes[_proposalId][msg.sender];
        require(currVotes >= _numVotes, "Insufficient votes to withdraw");

        uint256 price = (currVotes * currVotes) - (currVotes - _numVotes) * (currVotes - _numVotes);
        proposals[_proposalId].budget -= price * tokenPrice;
        votes[_proposalId][msg.sender] -= _numVotes;
        proposal.votes -= _numVotes;

        token.transferFrom(address(this), msg.sender, (price * tokenPrice)); 
        _checkAndExecuteProposal(_proposalId, _numVotes);
    }

    function getProposalInfo(uint _proposalId) public view returns (Proposal memory) {
        return proposals[_proposalId];
    }

    function getPendingProposals() public view voteOpen returns (uint[] memory) {
        return pendingProposals;
    }

    function getSignalingProposals() public view voteOpen returns (uint[] memory) {
        return signalingProposals;
    }

    function getApprovedProposals() public view voteOpen returns (uint[] memory) {
        return approvedProposals;
    }

    function _checkAndExecuteProposal(uint256 _proposalId, uint256 _votes) internal {
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.budget > 0, "Signaling proposals are not approved during the voting process");
        uint256 budget = totalBudget + proposal.budget;
        uint256 threshold = (2 + (proposal.budget * 10 / budget) * participantsNum + getPendingProposals().length * 10) / 10;
        
        if (_votes >= threshold && budget >= proposal.budget) {
            uint256 tokensToBurn = (proposal.availableBudget * (10 ** 18)) / tokenPrice;
            token.burn(address(this), tokensToBurn);

            totalBudget -= proposal.budget;
            proposal.status = ProposalStatus.Approved;
            approvedProposals.push(_proposalId);
            proposal.executableProposal.executeProposal{value: proposal.budget * tokenPrice, gas: 100000}(_proposalId, _votes, proposal.budget);
        }
        else {
            proposal.status = ProposalStatus.Rejected;
        }
    }

    function closeVoting() external onlyOwner voteOpen {
        uint256[] memory signalIds = getSignalingProposals();
        uint slen = signalIds.length;
        for (uint256 i = 0; i < slen; i++) {
            Proposal storage proposal = proposals[signalIds[i]];
            proposal.executableProposal.executeProposal(signalIds[i], proposal.votes, proposal.budget);
            proposal.status = ProposalStatus.Approved;
            refundingOpen = true;
            refundRequest(proposal);
            refundingOpen = false;
        }
        uint256[] memory pendingIds = getPendingProposals();
        uint plen = pendingIds.length;
        for (uint256 i = 0; i < plen; i++) {
            Proposal storage proposal = proposals[pendingIds[i]];
            if (proposal.status == ProposalStatus.Pending) {
                _checkAndExecuteProposal(i, proposal.votes);
            }

            if (proposal.status == ProposalStatus.Rejected) {
                refundingOpen = true;
                refundRequest(proposal);
                refundingOpen = false;
            }
        }
        uint256 remainingBudget = token.balanceOf(address(this));
        if (remainingBudget > 0) {
            token.transfer(owner(), remainingBudget);
        }
        votingOpen = false;
        proposalsNum = 0;
        participantsNum = 0;
        totalBudget = 0;
        delete proposals;
        delete signalingProposals;
        delete approvedProposals;
        delete pendingProposals;
    }

    function refundRequest(Proposal memory _proposal) internal onlyOwner refundOpen {
        address[] memory votersRefund = _proposal.voters;
        uint256 numVoters = votersRefund.length;
        for (uint256 j = 0; j < numVoters; j++) {
            address voter = votersRefund[j];
            uint256 numVotes = votes[_proposal.proposalId][voter];
            if (numVotes > 0) {
                uint256 returnedTokens = (numVotes * numVotes) / tokenPrice;
                _proposal.availableBudget -= returnedTokens;
                token.transfer(voter, returnedTokens);
            }
        }
    }
}