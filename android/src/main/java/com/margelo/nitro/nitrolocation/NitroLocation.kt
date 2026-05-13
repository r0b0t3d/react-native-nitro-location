package com.margelo.nitro.nitrolocation
  
import com.facebook.proguard.annotations.DoNotStrip

@DoNotStrip
class NitroLocation : HybridNitroLocationSpec() {
  override fun multiply(a: Double, b: Double): Double {
    return a * b
  }
}
