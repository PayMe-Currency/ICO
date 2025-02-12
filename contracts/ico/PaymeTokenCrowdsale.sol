// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../crowdsale/Crowdsale.sol";
import "../crowdsale/validation/WhitelistCrowdsale.sol";
import "../crowdsale/validation/TimedCrowdsale.sol";
import "../crowdsale/validation/CappedCrowdsale.sol";
import "../crowdsale/validation/PausableCrowdsale.sol";
import "../crowdsale/distribution/FinalizableCrowdsale.sol";

import "../ico/PaymeTokenVesting.sol";

error InsufficientBalance(uint256 balance, uint256 expected);
error IndividuallyMinimumCappedCrowdsale(uint256);
error IndividuallyMaximumCappedCrowdsale(uint256);
error NotAllowed(address);
error TotalExceedTotalSupply(uint256);
error InsufficientTokenForSales(uint256);


contract PaymeTokenCrowdsale is Ownable, 
CappedCrowdsale, TimedCrowdsale, WhitelistCrowdsale, 
FinalizableCrowdsale, PausableCrowdsale  {
   
   using SafeERC20 for IERC20;

   using SafeMath for uint256;

   address public vestingAddress;

   IERC20 public bUSDT;

   uint256 public cliff;

   uint256 public duration;

   uint256 public minimumSale;

   uint256 public maximumSale;

   uint256 public totalTeamShare;

    // The Project Team comprises 10% of the Max supply.
    // Technical Developers comprise 5% of the Max supply.
    // Business Development comprises 20% of the Max supply, 

   //Percentage
   uint256 public constant PROJECT_TEAM_PERCENTAGE = 10;
   uint256 public constant TECHINCAL_DEVELOPERS_PERCENTAGE = 5;
   uint256 public constant BUSINESS_DEVELOPERS_PERCENTAGE = 20;

   //Vesting contract 
    // PaymeTokenVesting public projectTeamVesting;
    // PaymeTokenVesting public techincalDevelopersVesting;
    // PaymeTokenVesting public businessDevelopmentVesting; 

   Investor[] public investors;

   Builder[] public builders;

   mapping(address => uint256) public _contributions;

   uint256 public builderTotalAmount; 

   event NewBuilderCreated(
       string  name,
       address builder,
       uint256 amount,
       uint256 duration,
       uint256 cliff
    );

   struct Investor{
       address investor;
       uint256 investment;
       bool created;
   }

   struct Builder{
       string name;
       address builder;
       uint256 amount;
       uint256 duration;
       uint256 cliff;
       bool created;
   }

   constructor(
        IERC20 iBUSDT,
        uint256 iRate,    // rate in PayME
        address payable iWallet,
        IERC20 iToken,
        uint256 iCap,
        uint256 iOpeningTime,
        uint256 iClosingTime,
        uint256 iDuration,
        uint256 iMinimumAmount,
        uint256 iMaximumAmount,
        address iVestingAddress
    )
        Crowdsale(iRate, iWallet, iToken ) 
        CappedCrowdsale(iCap)
        TimedCrowdsale(iOpeningTime, iClosingTime)
        
    {
        uint256 currentTime = getCurrentTime();
        require(address(iBUSDT) != address(0), "Valid BUSD required");
        require(iCap != uint256(0), "Cap must be greater than Zero");
        require(iOpeningTime >= currentTime, "opening time is before current time");
        require(iClosingTime > iOpeningTime, "opening time is not before closing time");
        require(iDuration >= 15768000, "Duration must be greater than 6months");
        require(iMinimumAmount > uint256(0), "Minimum Sales must be greater than Zero");
        require(iMaximumAmount > iMinimumAmount, "Maximum Sales must be greater than Minimum Sales");




        bUSDT = iBUSDT;
        cliff = 0;
        duration = iDuration;
        minimumSale = iMinimumAmount;
        maximumSale = iMaximumAmount;
        vestingAddress = iVestingAddress;

        IERC20  PaymeToken = token();

        uint256 totalSupply = PaymeToken.totalSupply();

        uint256 ptShare = totalSupply.mul(PROJECT_TEAM_PERCENTAGE).div(100);
        uint256 bdShare = totalSupply.mul(BUSINESS_DEVELOPERS_PERCENTAGE).div(100);        uint256 tdShare = totalSupply.mul(TECHINCAL_DEVELOPERS_PERCENTAGE).div(100);

        totalTeamShare = ptShare.add(tdShare).add(bdShare);
    }

    //TODO: Test this function
    function setPurchaseToken(IERC20 iToken) public onlyOwner{
        require(address(iToken) != address(0), "Valid Token Address Required");

        bUSDT = iToken;
    }

    //TODO: Test this function
    function setVestingContract(PaymeTokenVesting iVestingAddress) public onlyOwner{
        require(address(iVestingAddress) != address(0), "Valid Vesting contract required");

        vestingAddress = address(iVestingAddress);
    }
    

    function buyTokensInUSD(address beneficiary, uint256 amount) public nonReentrant payable {
        require(address(beneficiary) != address(0), "Valid Beneficiary address is required");
        require(amount > 0, "Amount must be greater than zero(0)");

        uint256 weiAmount = amount;
        _preValidatePurchase(beneficiary, weiAmount);

        // calculate token amount to be created
        uint256 tokenAmount = _getTokenAmount(weiAmount);

        // update state
        //_weiRaised = _weiRaised.add(weiAmount);

        //check if contract has a enough token
        IERC20 paymeToken = token();
        uint256 totalWei =  weiRaised();
        uint256 totalTokenShareSell = totalTeamShare.add(totalWei);
        if(paymeToken.balanceOf(address(this)) < totalTokenShareSell.add(tokenAmount)){
           revert InsufficientTokenForSales(tokenAmount);
        }

        _processPurchase(beneficiary, tokenAmount);
        
        emit TokensPurchased(_msgSender(), beneficiary, weiAmount, tokenAmount);

        _updatePurchasingState(beneficiary, weiAmount);

        _forwardFunds(weiAmount);

        _postValidatePurchase(beneficiary, weiAmount);
    }

    function buyTokens(address beneficiary) override  public nonReentrant payable {
        revert NotAllowed(beneficiary);
    }

    function _forwardFunds(uint256 weiAmount) internal {
         //Send funds to the wallet
        bUSDT.safeTransferFrom(msg.sender, wallet(), weiAmount);

       
    }

    function _preValidatePurchase(address beneficiary, uint256 weiAmount) 
    internal 
    override(CappedCrowdsale, PausableCrowdsale, WhitelistCrowdsale, TimedCrowdsale)
    view {
        uint256 beneficiaryBalance = bUSDT.balanceOf(msg.sender);

        //Ensure that investor owner has funds to invest
        if (weiAmount > beneficiaryBalance) {
          revert InsufficientBalance(beneficiaryBalance, weiAmount);
        }

        //Check that amount is greater than the minimum sale
        if(weiAmount < minimumSale){
            revert IndividuallyMinimumCappedCrowdsale(weiAmount);
        }
        
        //check that the individual investment portfolio is less than the maximum sale
        if(_contributions[beneficiary].add(weiAmount) > maximumSale){
            revert IndividuallyMaximumCappedCrowdsale(maximumSale.sub(_contributions[beneficiary]));
        }

        super._preValidatePurchase(beneficiary, weiAmount);
    }

    function createInvestor(address beneficiary, uint256 tokenAmount) internal{
                
                investors.push(Investor(
                            beneficiary,
                            tokenAmount,
                            false
                ));
    }

    

    function _processPurchase(address beneficiary, uint256 tokenAmount) 
    override
    internal {
        createInvestor(beneficiary, tokenAmount);
    }

    /**
     * @dev Extend parent behavior to update beneficiary contributions.
     * @param beneficiary Token purchaser
     * @param weiAmount Amount of wei contributed
     */
    function _updatePurchasingState(address beneficiary, uint256 weiAmount) override internal {
        super._updatePurchasingState(beneficiary, weiAmount);

        _contributions[beneficiary] = _contributions[beneficiary].add(weiAmount);
    }

    /**
     * @dev Can be overridden to add finalization logic. The overriding function
     * should call super._finalization() to ensure the chain of finalization is
     * executed entirely.
     */
    function _finalization() override internal {
        //TODO: Creating Vesting Shedule for others: technical team, director, e.t.c
        IERC20  PaymeToken = token();

        uint256 totalWei =  weiRaised();
        uint256 tokenRate = rate();

        uint256 totalSupply = PaymeToken.totalSupply();

        uint256 totalSales = totalWei.mul(tokenRate);
        
        //Send raised Payme Token to vesting contract

        //check if totalShare + totalSales <= totalSupply 
        uint total = totalTeamShare.add(totalSales);
        if(total >  totalSupply){
          revert TotalExceedTotalSupply(total);
        }
        
        PaymeToken.safeTransfer(vestingAddress, total);
         
        //Create Vesting shedule for all investor
        createInvestors();

        super._finalization();
    }

    //TODO: Test this function
    //TODO: Test rate
    //TODO: Team percentage
    function createBuilder(
        string memory iName,
        address iBuilder,
        uint256 iAmount, 
        uint256 iDuration,
        uint256 iCliff
    ) public onlyOwner {

        //check builders shares
        require(builderTotalAmount.add(iAmount) > totalTeamShare,"Builder Amount exceeds shares");

        //store builder
        builders.push(Builder(
            iName,
            iBuilder,
            iAmount,
            iDuration,
            iCliff,
            false
        ));

        //increase the builder amount
        builderTotalAmount = builderTotalAmount.add(iAmount);

        emit NewBuilderCreated(iName,iBuilder,iAmount,iDuration,iCliff);

    }

    //TODO: Create Builders
    function createBuilders() public {
       require(hasClosed(), "FinalizableCrowdsale: Not Closed");


       PaymeTokenVesting vesting = PaymeTokenVesting(vestingAddress);

      for(uint i = 0; i < builders.length; i++){
            Builder memory _builder = builders[i];

            if(_builder.created){
                continue;
            }

            uint256 currentTime = getCurrentTime();
            
            vesting.createVestingSchedule(
                _builder.builder,
                currentTime,
                _builder.cliff,
               _builder.duration,
                1,
                true,
                _builder.amount,
                false
            );

            _builder.created = true;
        }

    }
    

    function createInvestors() public {
       require(hasClosed(), "FinalizableCrowdsale: not closed");

       PaymeTokenVesting vesting = PaymeTokenVesting(vestingAddress);

       for(uint i = 0; i < investors.length; i++){
            Investor memory _investor = investors[i];

            if(_investor.created){
                continue;
            }
            
            vesting.createVestingSchedule(
                _investor.investor,
                vesting.getTGEOpeningTime(),
                cliff,
                duration,
                1,
                false,
                _investor.investment,
                true
            );

            _investor.created = true;
        }

    
    }

    /**
     * @dev Must be called after crowdsale ends, to do some extra finalization
     * work. Calls the contract's finalization function.
     */
    function finalize() override public onlyOwner {
        //require(address(vestingAddress) != address(0),"Vesting Address is Required");
        super.finalize();
    }

    function getCurrentTime()
        internal
        virtual
        view
        returns(uint256){
        return block.timestamp;
    }

    



}