func rect(_ x:Double,_ y:Double,_ w:Double,_ h:Double)->NSRect{NSRect(x:x,y:y,width:w,height:h)}
func panel(_ x:Double,_ y:Double)->NSRect{rect(x-140,y-140,280,280)}
let primary=PetScreenFacing.Screen(frame:rect(0,0,1440,900),visibleFrame:rect(0,30,1440,845))
func direction(_ x:Double,_ y:Double,_ displays:[PetScreenFacing.Screen]=[primary],preferred:Int?=nil)->PetScreenFacing.Direction{
 PetScreenFacing.direction(windowFrame:panel(x,y),screens:displays,preferred:preferred)!
}
precondition(direction(720,452.5) == .init(x:0,y:0),"center faces straight ahead")
precondition(direction(140,452.5) == .init(x:1,y:0),"left edge faces right")
precondition(direction(1300,452.5) == .init(x:-1,y:0),"right edge faces left")
precondition(direction(720,170) == .init(x:0,y:1),"bottom faces upward")
precondition(direction(720,735) == .init(x:0,y:-1),"top faces downward")
precondition(direction(140,170) == .init(x:1,y:1),"lower-left faces diagonally inward")
precondition(direction(1300,735) == .init(x:-1,y:-1),"upper-right faces diagonally inward")
let left=PetScreenFacing.Screen(frame:rect(-1920,-180,1920,1080),visibleFrame:rect(-1920,-155,1920,1030))
precondition(direction(-960,360,[primary,left],preferred:0) == .init(x:0,y:0),"secondary display negative origin uses its own center")
precondition(direction(-1780,360,[primary,left],preferred:0) == .init(x:1,y:0),"negative-origin left edge looks right")
precondition(direction(-140,360,[primary,left],preferred:0) == .init(x:-1,y:0),"largest intersection overrides stale window.screen")
let right=PetScreenFacing.Screen(frame:rect(1440,0,1440,900),visibleFrame:rect(1440,30,1440,845))
precondition(direction(1440,452.5,[primary,right],preferred:0).x == -1,"equal intersection honors preferred left display")
precondition(direction(1440,452.5,[primary,right],preferred:1).x == 1,"equal intersection honors preferred right display")
precondition(direction(4000,452.5,[primary,right],preferred:0).x == -1,"offscreen panel uses nearest display and clamps")
let above=PetScreenFacing.Screen(frame:rect(0,900,1440,900),visibleFrame:rect(0,930,1440,845))
precondition(direction(720,1352.5,[primary,above]).y == 0,"display above primary uses its own vertical center")
precondition(PetScreenFacing.direction(windowFrame:panel(0,0),screens:[]) == nil,"no screen safely emits no direction")
precondition(direction(720.01,452.5) == direction(720,452.5),"subpixel jitter is quantized")
precondition(direction(140,170).script == "window.setScreenFacing?.(1.0,1.0)","bridge preserves native up/right axes")
print("PASS: center/edges/corners, multiple displays, negative and vertical origins, overlap selection, preferred ties, offscreen clamp, no-screen safety, jitter dedup, JS axes")
